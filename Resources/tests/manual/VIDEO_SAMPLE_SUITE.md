# MP4 Tool manual video test suite

This suite includes short fixture clips in `tests/manual/videos/`; the original `VideoSamples/` folder is **not required**. It creates isolated input and output folders for each run, so MP4 Tool can safely process copies without changing the bundled fixtures. It is a **manual regression checklist**, not a guarantee that every downloaded edge-case sample is valid.

## Run a profile

From the project root:

```sh
bash tests/manual/prepare-video-samples.sh all
```

`all` includes all 11 distinct video fixtures in one batch; the expected result is 9 completed and 2 safely skipped. It includes the matching SRT beside `CDR-Dinner_LAN_800k.mp4`, so that file should gain a subtitle track. For shorter, focused reruns, replace `all` with `smoke`, `audio`, `subtitles`, `negative`, or `extended`. The script prints the new input and output paths. In MP4 Tool, choose the printed **input folder** via Open File/Folder, choose the printed **output folder** in Processing Setup, select **Default (Built-in)**, and run the queue. The default is Smart at 25 MB/min. Leave the default English audio/subtitle selection enabled, turn off any post-process script, and leave Delete Original off. Use one prepared profile per run; do not add the original `VideoSamples/` folder to the queue.

When MP4 Tool finishes, run the exact `python3 ... verify-video-samples.py ...` command printed by the preparer. The checker reads MP4 Tool's persistent processing log and probes/decodes each output independently. It reports `PASS` or `FAIL` for every input, checks expected skips and Smart decisions, and exits nonzero if anything is missing or wrong. A missing or unfinished app run reports `NOT RUN` or `INCOMPLETE`, never a false pass. You need `ffmpeg` and `ffprobe` on your `PATH`.

The preparer tries an APFS clone first and falls back to a normal copy. It never edits or deletes the bundled fixtures. Prepared folders are temporary test data; delete only the specific printed suite folder when you are finished with it.

The checker verifies the app's recorded validation result, output tracks/codecs/languages, duration, full FFmpeg decode, and that prepared inputs remain intact. An occasional human QuickTime/AVPlayer spot-check is still useful because command-line decoding cannot prove subjective playback quality or every Apple player behavior.

## Profiles and expected outcomes

The `all` profile combines the cases below without repeating videos. For its CDR case, use the `subtitles` expectation because `all` includes the sibling SRT.

| Profile | Input | Expected behavior |
| --- | --- | --- |
| `smoke` | `CDR-Dinner_LAN_800k.mp4` | Short, ordinary MP4. Completes and plays. No subtitle track. |
| `smoke` | `1Video_2Audio_2SUBs_timed_text_streams_.mp4` | Smart remux candidate. Keeps English audio and the English embedded text subtitle; does not retain the German alternates with default selection. |
| `smoke` | `H264+EAC3.mkv` | Smart chooses H.265 encode at this file's size per minute. E-AC-3 audio should be copied if the output validates; video and audio play. |
| `audio` | `090128_gszs02.mkv` | MP3 audio is not copied into MP4. Smart falls back to encode and produces compatible AAC audio. |
| `audio` | `mi2_vorbis51.mp4` | Vorbis audio is converted to AAC; output remains audible and playable. |
| `audio` | `vorbis-audio-switch.mkv` | Chooses one English audio track and converts Vorbis to AAC. Chooses an English embedded text subtitle. |
| `subtitles` | `CDR-Dinner_LAN_800k.mp4` plus matching `.en.srt` | With no usable embedded subtitle, selects the sibling SRT and writes one text subtitle to the MP4. |
| `subtitles` | `1Video_2Audio_2SUBs_timed_text_streams_.mp4` | Keeps the English embedded subtitle. It must not be displaced by a sidecar belonging to a different video. |
| `subtitles` | `vorbis-audio-switch.mkv` | Keeps one English embedded subtitle despite multiple embedded alternatives. |
| `negative` | `sample.mp4` | Audio-only MP4: imported by filename, then safely skipped with “No video track was found”; no output MP4. |
| `negative` | `turn-on-off.mp4` | Video with no audio: safely skipped under the default audio policy with “No audio tracks were found”; no output MP4. |
| `extended` | `NeroRecodeSample.mp4` | Multi-audio/bitmap-subtitle edge case. Confirm it is imported despite its name, with one selected audio track, no unsupported bitmap subtitle copied into MP4, and a playable result. |
| `extended` | `multiple_tracks.mkv` | Multiple video/audio/subtitle streams. Confirm one video, one selected audio, and one selected text subtitle in the playable output. |
| `extended` | `Matrix.Reloaded.Trailer-640x346-XviD-1.0beta2-HE_AAC_subtitled.mkv` | Many subtitle alternatives and an attached image. Confirm the actual movie video is used, one English subtitle is selected, and the result plays. |

The `extended` profile is exploratory: these are deliberately unusual third-party fixtures. If one fails, save its processing log and compare the actual stream choice/error with the expectation before treating it as a regression.

## What the short clips do and do not test

The fixtures were cut to about five seconds with stream copy, preserving the selected video/audio/subtitle codecs. Most start at the beginning of their source; `vorbis-audio-switch.mkv` starts near 11 seconds and the Matrix trailer starts near 24 seconds so both clips include subtitle cues. The Vorbis clip runs about 8 seconds because stream copy starts at an earlier keyframe. `multiple_tracks.mkv` runs about 7 seconds because its first subtitle cue extends past the five-second cut. The shortened `CDR-Dinner_LAN_800k.mp4` omits two unknown data streams that FFmpeg could not copy into MP4. The Matrix trailer needed generated presentation timestamps (`-fflags +genpts`); its original AAC had decode errors, so the fixture's audio was re-encoded to clean AAC while its video, subtitle alternatives, and cover track remain copied.

The suite keeps the original `sample.mp4` and `NeroRecodeSample.mp4` names to guard against reintroducing a silent filename filter. The separate Python/SAB workflow may still intentionally skip release samples; MP4 Tool's user-selected folder import should not.

These clips are good for quickly checking stream selection, codec fallback, subtitle handling, validation, and basic playback. They do **not** establish that a multi-hour encode will finish, that later-file corruption is caught, or that ETA and disk-space estimates remain accurate on large files. Use full-length media for those checks. The bundled clips derive from third-party test media; confirm redistribution rights before publishing them outside this project.

## Quick pass/fail checklist

- [ ] Smart's remux-versus-encode decisions match the expected cases above.
- [ ] Every expected success passes MP4 Tool's output validation and opens in QuickTime/AVPlayer.
- [ ] The selected audio plays; MP3/Vorbis sources become AAC, while compatible E-AC-3 is preserved when possible.
- [ ] Default selection keeps only the preferred English audio and subtitle tracks.
- [ ] A sibling SRT is used only where there is no usable embedded subtitle.
- [ ] Skipped/failed inputs remain untouched, with no final output file.
- [ ] Run History records the outcome, runtime, sizes, and command for completed runs.

If a case fails, record the profile, sample filename, MP4 Tool version, macOS version, FFmpeg version/source, the full per-file processing log, and whether the prepared input itself plays. Keep the prepared suite folder until diagnosis is complete.
