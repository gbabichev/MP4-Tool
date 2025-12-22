#!/usr/bin/env python3
"""List MP4 files whose audio tracks are DTS-only.

Requires ffprobe to be in the system path.

"""

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


def is_dts_only(codecs: list[str]) -> bool:
    if not codecs:
        return False
    return all(c.lower().startswith("dts") for c in codecs)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    if not root.exists():
        print(f"Root path not found: {root}", file=sys.stderr)
        return 2

    for path in sorted(root.rglob("*.mp4")):
        codecs = audio_codecs(path)
        if codecs is None:
            continue
        if is_dts_only(codecs):
            print(path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
