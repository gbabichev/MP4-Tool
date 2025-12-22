#!/usr/bin/env python3
"""Scan MP4 files and output a CSV of filename and audio codec(s).

Requires ffprobe to be in the system path.

"""

import csv
import json
import subprocess
import sys
from pathlib import Path


def audio_codecs(path: Path) -> list[str] | None:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "a",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "json",
        str(path),
    ]
    try:
        result = subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return None

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    streams = payload.get("streams", [])
    return [s.get("codec_name", "") for s in streams if s.get("codec_name")]


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    if not root.exists():
        print(f"Root path not found: {root}", file=sys.stderr)
        return 2

    output_path = Path("AudioScan_output.txt")

    paths = sorted(root.rglob("*.mp4"))
    total = len(paths)

    def show_progress(current: int) -> None:
        print(f"\rScanning {current}/{total}", end="", file=sys.stderr)

    with output_path.open("w", newline="") as handle:
        file_writer = csv.writer(handle)
        stdout_writer = csv.writer(sys.stdout)

        header = ["Filename", "AudioCodec"]
        file_writer.writerow(header)
        stdout_writer.writerow(header)

        for index, path in enumerate(paths, start=1):
            show_progress(index)
            codecs = audio_codecs(path)
            if codecs is None:
                continue
            codec_value = ";".join(codecs) if codecs else "unknown"
            row = [str(path), codec_value]
            file_writer.writerow(row)
            stdout_writer.writerow(row)

    if total:
        print(file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
