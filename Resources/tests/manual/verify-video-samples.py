#!/usr/bin/env python3
"""Check a prepared MP4 Tool video suite after the app finishes processing it."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Case:
    name: str
    outcome: str = "completed"
    decision: str | None = None
    audio_codec: str | None = "aac"
    subtitles: int = 0
    audio_language: str | None = None
    subtitle_language: str | None = None
    skip_reason: str | None = None


DUAL_TRACK = "1Video_2Audio_2SUBs_timed_text_streams_.mp4"
CDR = "CDR-Dinner_LAN_800k.mp4"
VORBIS_SWITCH = "vorbis-audio-switch.mkv"

PROFILES: dict[str, tuple[Case, ...]] = {
    "smoke": (
        Case(CDR, decision="Remux"),
        Case(DUAL_TRACK, decision="Remux", subtitles=1,
             audio_language="eng", subtitle_language="eng"),
        Case("H264+EAC3.mkv", decision="Encode H.265", audio_codec="eac3",
             audio_language="eng"),
    ),
    "audio": (
        Case("090128_gszs02.mkv", decision="Encode H.265", subtitles=1),
        Case("mi2_vorbis51.mp4", decision="Encode H.265", subtitles=1),
        Case(VORBIS_SWITCH, decision="Encode H.265", subtitles=1,
             audio_language="eng", subtitle_language="eng"),
    ),
    "subtitles": (
        Case(CDR, decision="Remux", subtitles=1, subtitle_language="eng"),
        Case(DUAL_TRACK, decision="Remux", subtitles=1,
             audio_language="eng", subtitle_language="eng"),
        Case(VORBIS_SWITCH, decision="Encode H.265", subtitles=1,
             audio_language="eng", subtitle_language="eng"),
    ),
    "negative": (
        Case("sample.mp4", outcome="skipped", audio_codec=None,
             skip_reason="No video track was found"),
        Case("turn-on-off.mp4", outcome="skipped", audio_codec=None,
             skip_reason="No audio tracks were found"),
    ),
    "extended": (
        Case("NeroRecodeSample.mp4", subtitles=0, audio_language="eng"),
        Case("multiple_tracks.mkv", decision="Encode H.265", subtitles=1,
             subtitle_language="eng"),
        Case("Matrix.Reloaded.Trailer-640x346-XviD-1.0beta2-HE_AAC_subtitled.mkv",
             decision="Remux", subtitles=1, audio_language="eng",
             subtitle_language="eng"),
    ),
}
PROFILES["all"] = (
    PROFILES["subtitles"][0],  # The sibling-SRT variant of the CDR fixture.
    *PROFILES["smoke"][1:],
    *PROFILES["audio"],
    *PROFILES["negative"],
    *PROFILES["extended"],
)


@dataclass
class FileResult:
    input_path: str
    planned_output: str | None = None
    final_output: str | None = None
    decision: str | None = None
    status: str | None = None
    reason: str | None = None
    validated: bool = False
    finished: bool = False


@dataclass
class Run:
    lines: list[str]
    files: dict[str, FileResult] = field(default_factory=dict)
    duplicate_inputs: set[str] = field(default_factory=set)


LOG_PREFIX = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}  ")
RUN_MARKER = "═══ MP4 Tool Processing Run ═══"


def message(line: str) -> str:
    return LOG_PREFIX.sub("", line).strip()


def read_log(log_file: Path | None) -> list[str]:
    if log_file is not None:
        paths = [log_file]
    else:
        directory = Path.home() / "Library/Application Support/MP4 Tool/Logs"
        paths = [directory / f"MP4 Tool.{number}.log" for number in range(5, 0, -1)]
        paths.append(directory / "MP4 Tool.log")
    return [message(line) for path in paths if path.is_file()
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines()]


def split_runs(lines: list[str]) -> list[Run]:
    runs: list[Run] = []
    current: list[str] | None = None
    for line in lines:
        if RUN_MARKER in line:
            current = []
            runs.append(Run(current))
        if current is not None:
            current.append(line)
    return runs


def field(lines: list[str], label: str) -> str | None:
    for line in lines:
        marker = f"{label}: "
        if marker in line:
            return line.split(marker, 1)[1].strip()
    return None


def latest_suite_run(runs: list[Run], input_dir: Path, output_dir: Path) -> Run | None:
    for run in reversed(runs):
        if field(run.lines, "Output Directory") == str(output_dir) and (
            field(run.lines, "Input Directory") == str(input_dir)
            or any(f"Input: {input_dir}/" in line for line in run.lines)
        ):
            return run
    return None


def parse_file_results(run: Run) -> None:
    current: FileResult | None = None
    for line in run.lines:
        if line.startswith("Input: "):
            path = line.removeprefix("Input: ")
            if path in run.files:
                run.duplicate_inputs.add(path)
            current = FileResult(input_path=path)
            run.files[path] = current
        elif current is None:
            continue
        elif line.startswith("Output: "):
            current.planned_output = line.removeprefix("Output: ")
        elif "Smart Decision: " in line:
            current.decision = line.split("Smart Decision: ", 1)[1]
        elif "Output validation passed" in line:
            current.validated = True
        elif line.startswith("Final Output: "):
            current.final_output = line.removeprefix("Final Output: ")
        elif "SKIPPED: " in line:
            current.status = "skipped"
        elif "FAILED: " in line:
            current.status = "failed"
        elif line.startswith("Reason: "):
            current.reason = line.removeprefix("Reason: ")
        elif "Done processing" in line:
            current.status = "completed"
            current.finished = True


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def probe(path: Path, ffprobe: str) -> dict:
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True, text=True, check=False, timeout=30,
    )
    if result.returncode:
        raise ValueError(f"ffprobe failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def decode(path: Path, ffmpeg: str) -> None:
    result = subprocess.run(
        [ffmpeg, "-nostdin", "-v", "error", "-i", str(path),
         "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if result.returncode or result.stderr.strip():
        raise ValueError(f"FFmpeg decode failed: {result.stderr.strip() or result.returncode}")


def is_inside(path: Path, directory: Path) -> bool:
    return path == directory or directory in path.parents


def check_output(
    case: Case, output_path: Path, output_dir: Path, result: FileResult,
    ffprobe: str, ffmpeg: str,
) -> list[str]:
    problems: list[str] = []
    resolved = output_path.resolve()
    if not is_inside(resolved, output_dir.resolve()):
        return ["final output is outside the prepared output folder"]
    if not output_path.is_file() or output_path.suffix.lower() != ".mp4":
        return ["final MP4 is missing"]
    if not result.validated:
        problems.append("app log does not show output validation passing")
    if not result.finished:
        problems.append("app log does not show processing completing")

    try:
        metadata = probe(output_path, ffprobe)
    except (ValueError, subprocess.TimeoutExpired) as error:
        return problems + [str(error)]
    streams = metadata.get("streams", [])
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    subtitles = [stream for stream in streams if stream.get("codec_type") == "subtitle"]
    extra = [stream for stream in streams if stream.get("codec_type") not in {"video", "audio", "subtitle"}]
    if len(videos) != 1:
        problems.append(f"expected 1 video track, found {len(videos)}")
    if len(audios) != 1:
        problems.append(f"expected 1 audio track, found {len(audios)}")
    if len(subtitles) != case.subtitles:
        problems.append(f"expected {case.subtitles} subtitle track(s), found {len(subtitles)}")
    if extra:
        problems.append(f"unexpected auxiliary track(s): {len(extra)}")

    if videos and result.decision:
        expected_video = "hevc" if result.decision == "Encode H.265" else None
        if result.decision == "Remux":
            expected_video = "h264" if case.name.endswith("H264+EAC3.mkv") else "mpeg4"
        if expected_video and videos[0].get("codec_name") != expected_video:
            problems.append(f"video codec is {videos[0].get('codec_name')}, expected {expected_video}")
    if audios and case.audio_codec and audios[0].get("codec_name") != case.audio_codec:
        problems.append(f"audio codec is {audios[0].get('codec_name')}, expected {case.audio_codec}")
    if subtitles and any(stream.get("codec_name") != "mov_text" for stream in subtitles):
        problems.append("subtitle track is not MP4 text (mov_text)")
    if audios and case.audio_language and (
        audios[0].get("tags", {}).get("language", "und").lower() != case.audio_language
    ):
        problems.append(f"audio language is not {case.audio_language}")
    if subtitles and case.subtitle_language and (
        subtitles[0].get("tags", {}).get("language", "und").lower() != case.subtitle_language
    ):
        problems.append(f"subtitle language is not {case.subtitle_language}")
    try:
        duration = float(metadata.get("format", {}).get("duration", 0))
        if not 2 <= duration <= 30:
            problems.append(f"unexpected output duration: {duration:.2f}s")
    except (TypeError, ValueError):
        problems.append("output duration is unavailable")
    if len(videos) == 1 and len(audios) == 1:
        try:
            decode(output_path, ffmpeg)
        except (ValueError, subprocess.TimeoutExpired) as error:
            problems.append(str(error))
    return problems


def verify(suite: Path, profile: str, log_file: Path | None) -> int:
    input_dir = suite / "input"
    output_dir = suite / "output"
    if not input_dir.is_dir() or not output_dir.is_dir():
        print("ERROR: expected input/ and output/ inside the prepared suite folder")
        return 2
    ffprobe = shutil.which("ffprobe")
    ffmpeg = shutil.which("ffmpeg")
    if not ffprobe or not ffmpeg:
        print("ERROR: ffmpeg and ffprobe must be available on PATH")
        return 2

    lines = read_log(log_file)
    run = latest_suite_run(split_runs(lines), input_dir, output_dir)
    if run is None:
        print("NOT RUN: no MP4 Tool processing log matches this suite's input and output folders")
        print("Finish the run in MP4 Tool, then run this checker again.")
        return 2
    if not any("═══ Batch Summary ═══" in line for line in run.lines) or not field(run.lines, "Finished"):
        print("INCOMPLETE: the matching MP4 Tool run has no finished batch summary")
        return 2
    parse_file_results(run)

    global_problems: list[str] = []
    expected_settings = (
        ("Mode", "smart"),
        ("Smart Target", "25 MB/min"),
        ("Delete Original", "false"),
        ("Keep English Audio Only", "true"),
        ("Keep All English Audio Tracks", "false"),
        ("Keep English Subtitles Only", "true"),
        ("Keep All English Subtitle Tracks", "false"),
    )
    for label, expected in expected_settings:
        actual = field(run.lines, label)
        if actual is None or actual.lower() != expected.lower():
            global_problems.append(f"{label} is {actual or 'not recorded'}; expected {expected}")
    if field(run.lines, "Post-Process Script"):
        global_problems.append("a post-process script was enabled for this test run")
    if field(run.lines, "Status") == "Cancelled":
        global_problems.append("the batch was cancelled")

    passed = 0
    failed = 0
    expected_outputs: set[Path] = set()
    for case in PROFILES[profile]:
        problems: list[str] = []
        source = input_dir / case.name
        fixture = Path(__file__).resolve().parent / "videos" / case.name
        if not source.is_file():
            problems.append("prepared input file is missing")
        elif not fixture.is_file() or sha256(source) != sha256(fixture):
            problems.append("prepared input no longer matches its bundled fixture")

        result = run.files.get(str(source))
        if not result:
            problems.append("file is absent from the matching processing run")
        elif str(source) in run.duplicate_inputs:
            problems.append("file was processed more than once in the run")
        elif case.outcome == "skipped":
            if result.status != "skipped":
                problems.append(f"expected safe skip, got {result.status or 'no outcome'}")
            if result.reason != case.skip_reason:
                problems.append(f"skip reason is {result.reason!r}; expected {case.skip_reason!r}")
            if result.final_output:
                problems.append("skipped file has a final output")
        else:
            if result.status != "completed":
                problems.append(f"expected completion, got {result.status or 'no outcome'}"
                                  + (f" ({result.reason})" if result.reason else ""))
            if case.decision and result.decision != case.decision:
                problems.append(f"Smart chose {result.decision or 'nothing'}; expected {case.decision}")
            if not result.final_output:
                problems.append("processing log has no final output path")
            else:
                output_path = Path(result.final_output)
                expected_outputs.add(output_path.resolve())
                problems.extend(check_output(case, output_path, output_dir, result, ffprobe, ffmpeg))

        if problems:
            failed += 1
            print(f"FAIL  {case.name}")
            for problem in problems:
                print(f"      - {problem}")
        else:
            passed += 1
            print(f"PASS  {case.name}")

    actual_outputs = {path.resolve() for path in output_dir.rglob("*")
                      if path.is_file() and path.suffix.lower() == ".mp4"}
    for extra in sorted(actual_outputs - expected_outputs):
        global_problems.append(f"unexpected MP4 in output folder: {extra}")
    for extra_input in sorted(set(run.files) - {str(input_dir / case.name) for case in PROFILES[profile]}):
        global_problems.append(f"unexpected input in processing run: {extra_input}")
    for problem in global_problems:
        print(f"FAIL  suite: {problem}")

    print(f"\n{profile}: {passed} passed, {failed} failed"
          + (f", {len(global_problems)} suite issue(s)" if global_problems else ""))
    return 1 if failed or global_problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", type=Path, help="folder printed by prepare-video-samples.sh")
    parser.add_argument("--profile", choices=PROFILES, help="override the profile inferred from the folder name")
    parser.add_argument("--log-file", type=Path, help="use a specific MP4 Tool log file")
    args = parser.parse_args()
    suite = args.suite.expanduser().resolve()
    match = re.match(r"^mp4tool-video-suite\.([a-z]+)\.", suite.name)
    profile = args.profile or (match.group(1) if match else None)
    if profile not in PROFILES:
        parser.error("cannot infer profile from suite folder name; pass --profile")
    return verify(suite, profile, args.log_file)


if __name__ == "__main__":
    sys.exit(main())
