#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s {all|smoke|audio|subtitles|negative|extended}\n' "${0##*/}" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
profile=$1

case "$profile" in
    all)
        files=(
            'CDR-Dinner_LAN_800k.mp4'
            '1Video_2Audio_2SUBs_timed_text_streams_.mp4'
            'H264+EAC3.mkv'
            '090128_gszs02.mkv'
            'mi2_vorbis51.mp4'
            'vorbis-audio-switch.mkv'
            'sample.mp4'
            'turn-on-off.mp4'
            'NeroRecodeSample.mp4'
            'multiple_tracks.mkv'
            'Matrix.Reloaded.Trailer-640x346-XviD-1.0beta2-HE_AAC_subtitled.mkv'
        )
        ;;
    smoke)
        files=(
            'CDR-Dinner_LAN_800k.mp4'
            '1Video_2Audio_2SUBs_timed_text_streams_.mp4'
            'H264+EAC3.mkv'
        )
        ;;
    audio)
        files=(
            '090128_gszs02.mkv'
            'mi2_vorbis51.mp4'
            'vorbis-audio-switch.mkv'
        )
        ;;
    subtitles)
        files=(
            'CDR-Dinner_LAN_800k.mp4'
            '1Video_2Audio_2SUBs_timed_text_streams_.mp4'
            'vorbis-audio-switch.mkv'
        )
        ;;
    negative)
        files=(
            'sample.mp4'
            'turn-on-off.mp4'
        )
        ;;
    extended)
        files=(
            'NeroRecodeSample.mp4'
            'multiple_tracks.mkv'
            'Matrix.Reloaded.Trailer-640x346-XviD-1.0beta2-HE_AAC_subtitled.mkv'
        )
        ;;
    *) usage ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
samples_dir="$script_dir/videos"

for file in "${files[@]}"; do
    if [[ ! -f "$samples_dir/$file" ]]; then
        printf 'Missing bundled test clip: %s\n' "$samples_dir/$file" >&2
        exit 1
    fi
done

scratch_base=${TMPDIR:-/tmp}
suite_root=$(mktemp -d "${scratch_base%/}/mp4tool-video-suite.${profile}.XXXXXX")
mkdir -p "$suite_root/input" "$suite_root/output"

for file in "${files[@]}"; do
    # Clone on APFS to keep test runs cheap; copy normally on other volumes.
    if ! cp -c "$samples_dir/$file" "$suite_root/input/$file" 2>/dev/null; then
        cp "$samples_dir/$file" "$suite_root/input/$file"
    fi
done

if [[ "$profile" == subtitles || "$profile" == all ]]; then
    cp "$script_dir/fixtures/CDR-Dinner_LAN_800k.en.srt" "$suite_root/input/"
fi

printf 'Prepared %s suite in: %s\n' "$profile" "$suite_root"
printf 'Expected MP4 Tool queue: %s video file(s)\n' "${#files[@]}"
if [[ "$profile" == subtitles || "$profile" == all ]]; then
    printf 'The additional .srt is a subtitle sidecar, not a queue item.\n'
fi
printf 'Open this input folder in MP4 Tool: %s\n' "$suite_root/input"
printf 'Set the output folder to:       %s\n' "$suite_root/output"
printf 'Expected results: %s\n' "$script_dir/VIDEO_SAMPLE_SUITE.md"
printf 'After processing finishes, check the run with:\n'
printf '  python3 "%s/verify-video-samples.py" "%s"\n' "$script_dir" "$suite_root"
printf 'Bundled test clips were not changed.\n'
