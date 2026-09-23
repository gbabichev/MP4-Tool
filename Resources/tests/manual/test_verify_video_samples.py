"""Small unit checks for the post-run verifier; no MP4 Tool launch required."""

import importlib.util
import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-video-samples.py")
SPEC = importlib.util.spec_from_file_location("video_sample_verifier", SCRIPT)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
import sys
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)


class VerifyVideoSamplesTests(unittest.TestCase):
    def test_all_profile_covers_each_fixture_once(self):
        names = [case.name for case in VERIFIER.PROFILES["all"]]
        focused_names = {
            case.name for profile, cases in VERIFIER.PROFILES.items()
            if profile != "all" for case in cases
        }
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(names), focused_names)
        self.assertEqual(len(names), 11)
        self.assertEqual(VERIFIER.PROFILES["all"][0].subtitles, 1)

    def test_selects_latest_matching_run(self):
        input_dir = Path("/tmp/mp4tool-video-suite.smoke.test/input")
        output_dir = input_dir.parent / "output"
        lines = [
            VERIFIER.RUN_MARKER,
            f"Output Directory: {output_dir}",
            f"Input: {input_dir / 'old.mp4'}",
            VERIFIER.RUN_MARKER,
            f"Output Directory: {output_dir}",
            f"Input: {input_dir / 'new.mp4'}",
        ]
        run = VERIFIER.latest_suite_run(VERIFIER.split_runs(lines), input_dir, output_dir)
        self.assertIsNotNone(run)
        self.assertIn("new.mp4", "\n".join(run.lines))

    def test_parses_file_outcomes(self):
        run = VERIFIER.Run([
            "Input: /tmp/a.mp4",
            "Output: /tmp/output/a.mp4",
            "Smart Decision: Remux",
            "Output validation passed",
            "Done processing",
            "Final Output: /tmp/output/a.mp4",
            "Input: /tmp/b.mp4",
            "SKIPPED: b.mp4",
            "Reason: No video track was found",
        ])
        VERIFIER.parse_file_results(run)
        self.assertEqual(run.files["/tmp/a.mp4"].status, "completed")
        self.assertTrue(run.files["/tmp/a.mp4"].validated)
        self.assertEqual(run.files["/tmp/a.mp4"].decision, "Remux")
        self.assertEqual(run.files["/tmp/b.mp4"].status, "skipped")
        self.assertEqual(run.files["/tmp/b.mp4"].reason, "No video track was found")

    def test_known_good_short_mp4_passes_independent_probe(self):
        ffprobe = shutil.which("ffprobe")
        ffmpeg = shutil.which("ffmpeg")
        if not ffprobe or not ffmpeg:
            self.skipTest("ffmpeg and ffprobe not available")
        path = Path(__file__).parent / "videos" / VERIFIER.CDR
        result = VERIFIER.FileResult(
            input_path="/tmp/input/CDR-Dinner_LAN_800k.mp4",
            decision="Remux", status="completed", validated=True, finished=True,
            final_output=str(path),
        )
        self.assertEqual(
            VERIFIER.check_output(
                VERIFIER.PROFILES["smoke"][0], path, path.parent, result, ffprobe, ffmpeg
            ),
            [],
        )

    def test_complete_negative_run_passes_without_outputs(self):
        if not shutil.which("ffprobe") or not shutil.which("ffmpeg"):
            self.skipTest("ffmpeg and ffprobe not available")
        with tempfile.TemporaryDirectory(prefix="mp4tool-video-suite.negative.") as directory:
            suite = Path(directory)
            input_dir = suite / "input"
            output_dir = suite / "output"
            input_dir.mkdir()
            output_dir.mkdir()
            for case in VERIFIER.PROFILES["negative"]:
                shutil.copy2(Path(__file__).parent / "videos" / case.name, input_dir / case.name)
            log = suite / "test.log"
            log.write_text("\n".join([
                VERIFIER.RUN_MARKER,
                f"Input Directory: {input_dir}",
                f"Output Directory: {output_dir}",
                "Mode: smart",
                "Smart Target: 25 MB/min",
                "Delete Original: false",
                "Keep English Audio Only: true",
                "Keep All English Audio Tracks: false",
                "Keep English Subtitles Only: true",
                "Keep All English Subtitle Tracks: false",
                f"Input: {input_dir / 'sample.mp4'}",
                f"Output: {output_dir / 'sample.mp4'}",
                "SKIPPED: sample.mp4",
                "Reason: No video track was found",
                f"Input: {input_dir / 'turn-on-off.mp4'}",
                f"Output: {output_dir / 'turn-on-off.mp4'}",
                "SKIPPED: turn-on-off.mp4",
                "Reason: No audio tracks were found",
                "═══ Batch Summary ═══",
                "Status: Completed",
                "Finished: 2026-09-23T12:00:00Z",
            ]), encoding="utf-8")
            report = io.StringIO()
            with redirect_stdout(report):
                status = VERIFIER.verify(suite, "negative", log)
            self.assertEqual(status, 0, report.getvalue())
            self.assertIn("negative: 2 passed, 0 failed", report.getvalue())


if __name__ == "__main__":
    unittest.main()
