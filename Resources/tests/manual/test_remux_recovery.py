#!/usr/bin/env python3
"""Exercise the real Swift converter with generated media and injected FFmpeg faults.

Requires macOS, Xcode, and ffmpeg/ffprobe on PATH. Compiles temporary copies of
the app sources with an isolated entry point; never launches or changes the app.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]

HARNESS = r'''
@main
struct RemuxRecoveryTests {
    @MainActor static func main() async {
        await VideoProcessor.runRecoveryTest()
    }
}

extension VideoProcessor {
    @MainActor static func runRecoveryTest() async {
        let args = CommandLine.arguments
        let processor = VideoProcessor(testFFmpegPath: args[1], testFFprobePath: args[2])
        processor.framePreviewsEnabled = false
        let duration = Double(args[6])!
        processor.currentInputDurationSeconds = duration
        if args[5] == "cancelled" { processor.shouldCancelProcessing = true }
        let outcome = await processor.convertToMP4(
            inputFile: args[3], tempFile: args[4], mode: .remux,
            smartRemuxMegabytesPerMinute: 25, preset: .ultrafast,
            encodeVideo: false, encodeAudio: false,
            keepEnglishAudioOnly: false, keepAllEnglishAudioTracks: true,
            keepEnglishSubtitlesOnly: false, keepAllEnglishSubtitleTracks: true,
            sourceDuration: duration
        )
        switch outcome {
        case .success(let mode): print("TEST_RESULT=success:" + mode.rawValue)
        case .failed(let reason): print("TEST_RESULT=failed:" + reason)
        case .skipped(let reason): print("TEST_RESULT=skipped:" + reason)
        }
    }
}
'''

SHIM = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ["RECOVERY_STATE"])
calls = json.loads(state.read_text()) if state.exists() else []
calls.append(args)
state.write_text(json.dumps(calls))
case = os.environ["RECOVERY_CASE"]
first = len(calls) == 1
if case == "fallback_failure" or (first and case in ("remux_exit", "disk_full")):
    print("No space left on device" if case == "disk_full" else "Injected mux failure", file=sys.stderr)
    sys.exit(1)
if first and case == "truncated":
    args[-1:-1] = ["-t", "2"]
result = subprocess.run([os.environ["REAL_FFMPEG"], *args])
if result.returncode == 0:
    # Reproduce the old mux-level timestamp even with a newer FFmpeg build.
    print("out_time=00:00:00.500000\nprogress=end", file=sys.stderr)
sys.exit(result.returncode)
'''


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, help="Also validate MKV samples from this folder")
    options = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    assert ffmpeg and ffprobe, "Install ffmpeg and ffprobe first"
    with tempfile.TemporaryDirectory(prefix="mp4-remux-tests-") as directory:
        work = Path(directory)
        sources = []
        dependencies = (
            "VideoProcessor", "AudioTrackSelectionPolicy", "SubtitleTrackSelectionPolicy",
            "AutomaticVideoFileNamer", "ProcessingStagingStorage", "ProcessingHistoryStore",
            "PersistentProcessingLog", "SystemSleepAssertion",
        )
        for name in dependencies:
            source = ROOT / "MP4 Tool" / "Logic" / f"{name}.swift"
            text = source.read_text()
            if source.name == "VideoProcessor.swift":
                # Bypass production startup (including staging cleanup) and disk
                # logging. Conversion and validation code stays unchanged.
                text = text.replace("    init() {", '''    init(testFFmpegPath: String, testFFprobePath: String) {
        self.ffmpegPath = testFFmpegPath
        self.ffprobePath = testFFprobePath
    }

    init() {''', 1)
                text = text.replace("PersistentProcessingLog.shared.append(message)", "")
                text += HARNESS
            target = work / source.name
            target.write_text(text)
            sources.append(str(target))
        executable = work / "recovery-tests"
        print("Compiling Swift converter integration tests...", flush=True)
        run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
             "-default-isolation", "MainActor", "-enable-upcoming-feature",
             "NonisolatedNonsendingByDefault", "-enable-upcoming-feature",
             "InferIsolatedConformances", "-module-cache-path", str(work / "modules"),
             *sources, "-o", str(executable)], stdout=subprocess.PIPE)

        subtitle = work / "short.srt"
        subtitle.write_text("1\n00:00:00,000 --> 00:00:00,500\nShort subtitle\n")
        fixture = work / "source.mkv"
        run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24:duration=12",
             "-f", "lavfi", "-i", "sine=frequency=440:duration=12", "-i", str(subtitle),
             "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264",
             "-preset", "ultrafast", "-c:a", "aac", "-c:s", "srt", str(fixture)])
        original_hash = hashlib.sha256(fixture.read_bytes()).digest()
        incompatible = work / "ffv1.mkv"
        run([ffmpeg, "-v", "error", "-i", str(fixture), "-map", "0", "-c", "copy",
             "-c:v", "ffv1", str(incompatible)])
        shim = work / "ffmpeg-shim"
        shim.write_text(SHIM)
        shim.chmod(0o755)

        cases = {
            "short_progress": ("success:remux", 1),
            "remux_exit": ("success:encode_h265", 3),
            "truncated": ("success:encode_h265", 3),
            "fallback_failure": ("failed:", 2),
            "disk_full": ("failed:", 1),
            "cancelled": ("failed:Cancelled by user", 0),
            "unsupported_codec": ("success:encode_h265", 2),
        }
        for case, (expected, count) in cases.items():
            output = work / f"{case}.mp4"
            state = work / f"{case}.json"
            source = incompatible if case == "unsupported_codec" else fixture
            result = run([str(executable), str(shim), ffprobe, str(source), str(output), case, "12"],
                         env={**os.environ, "REAL_FFMPEG": ffmpeg, "RECOVERY_CASE": case,
                              "RECOVERY_STATE": str(state)}, capture_output=True)
            outcomes = [line for line in result.stdout.splitlines() if line.startswith("TEST_RESULT=")]
            assert len(outcomes) == 1, result.stdout + result.stderr
            assert outcomes[0].startswith("TEST_RESULT=" + expected), result.stdout + result.stderr
            calls = json.loads(state.read_text()) if state.exists() else []
            assert len(calls) == count, (case, calls)
            if expected.startswith("success"):
                probe = json.loads(run([ffprobe, "-v", "error", "-show_streams", "-show_format",
                                       "-of", "json", str(output)], capture_output=True).stdout)
                assert abs(float(probe["format"]["duration"]) - 12) < 0.1, probe
                video = next(s for s in probe["streams"] if s["codec_type"] == "video")
                assert video["codec_name"] == ("h264" if case == "short_progress" else "hevc"), probe
                assert any(s["codec_type"] == "subtitle" for s in probe["streams"]), probe
            if case == "truncated":
                assert "video duration mismatch" in result.stdout, result.stdout
            assert hashlib.sha256(fixture.read_bytes()).digest() == original_hash
            assert not list(work.glob("*-av.mp4")), "Intermediate output leaked"
            print(f"PASS {case}", flush=True)

        if options.samples:
            for source in sorted(options.samples.glob("*.mkv")):
                probe = json.loads(run([ffprobe, "-v", "error", "-show_format", "-of", "json",
                                       str(source)], capture_output=True).stdout)
                duration = probe["format"]["duration"]
                output = work / "sample-output.mp4"
                result = run([str(executable), ffmpeg, ffprobe, str(source), str(output), "sample", duration],
                             capture_output=True)
                assert "TEST_RESULT=success:remux" in result.stdout, result.stdout + result.stderr
                output.unlink()
                print(f"PASS sample: {source.name}", flush=True)


if __name__ == "__main__":
    main()
