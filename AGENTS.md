AGENTS.md

Project: MP4 Tool (macOS SwiftUI)

Overview
- Main window: `MP4 Tool/Views/ContentView.swift`
- Settings panel: `MP4 Tool/Views/SettingsView.swift` + `MP4 Tool/Views/SettingsToggleSection.swift`
- Video Splitter window: `MP4 Tool/Views/VideoSplitterView.swift`
- Video Splitter logic: `MP4 Tool/Logic/VideoSplitterViewModel.swift`
- Offset Checker window: `MP4 Tool/Views/OffsetStartCheckerView.swift`
- Offset Checker logic: `MP4 Tool/Logic/OffsetStartCheckerViewModel.swift`
- Non-MP4 Scanner window: `MP4 Tool/Views/NonMP4ScannerView.swift`
- Non-MP4 Scanner logic: `MP4 Tool/Logic/NonMP4ScannerViewModel.swift`
- MP4 Validation window: `MP4 Tool/Views/MP4ValidationView.swift`
- MP4 Validation logic: `MP4 Tool/Logic/MP4ValidationViewModel.swift`
- Subtitle Merger window: `MP4 Tool/Views/SubtitleMuxerView.swift`
- Subtitle Merger logic: `MP4 Tool/Logic/SubtitleMuxerViewModel.swift`
- Shared rename logic: `MP4 Tool/Logic/AutomaticVideoFileNamer.swift`
- App scenes/menus: `MP4 Tool/MP4_ToolApp.swift`

UI conventions
- Settings panels use GroupBox with slightly smaller type, compact spacing.
- Settings row labels use `.subheadline`; controls are compact (`.controlSize(.small)`).
- Content should be top-aligned within windows (`.frame(..., alignment: .topLeading)`).
- Main window places Settings on the left and main processing content on the right.
- Main window toolbar includes a settings visibility toggle (`Hide Settings` / `Show Settings`) to fully hide/show the settings pane.
- Video Splitter uses:
  - Folder pickers for input/output with `Open` buttons to reveal selected folders in Finder
  - Detection settings with captions
  - Progress + Stop for scanning
  - Split candidates list with checkbox + preview line
  - Red on-screen warning text (no modal alert) for scan mismatch

Video Splitter behavior
- Tools menu opens a separate window scene:
  - Scene is `Window("Video Splitter", id: "videoSplitter")`
- Scanning uses FFmpeg blackdetect with adjustable:
  - BLACK_MIN_DURATION (blackMinDuration)
  - BLACK_THRESHOLD_SECONDS (blackThresholdSeconds)
  - PIC_THRESHOLD (picThreshold)
  - Optional “scan around halfway” window (requires ffprobe)
- Scan order: natural sort (localizedStandardCompare) to avoid E01/E10 issues.
- Cancel scan:
  - Cancels task and terminates in-flight ffmpeg process.
  - Uses a scan token to ignore stale updates.

Offset Checker behavior
- Tools menu opens a separate window scene:
  - Scene is `Window("Check Offset Starts", id: "offsetStartChecker")`
- Scan behavior:
  - Input picker selects a root folder.
  - Scan is recursive (includes subfolders).
  - File ordering is stable natural sort by relative path (`localizedStandardCompare`).
  - Uses ffprobe first video packet `pts_time` (`-select_streams v:0`, `-show_entries packet=pts_time`, `-read_intervals %+#1`).
  - Small offsets are ignored via a significance threshold (`0.50s`).
- Fix behavior:
  - `Fix Offsets` targets only files flagged with significant offsets.
  - Uses ffmpeg remux flags: `-map 0 -c copy -avoid_negative_ts make_zero`.
  - Validates remux output with ffprobe before replacing original.
  - If remux fails validation for any reason, file is flagged `FAIL: Please Re-Encode` and original is kept.
  - Replacement is in-place via temp file + atomic replace only when validation succeeds.
  - Includes progress + Stop; cancel terminates in-flight process.
- Toolbar actions:
  - `Choose Folder...`
  - `Send Failed to Main` (pushes failed file paths into the main app "Files to Process" list)
  - `Export Failures...` writes a `.txt` list of failed file paths via save dialog
- Folder section:
  - Inline `Open` button appears to the left of `Input Folder` and opens the selected folder in Finder.
- Scan Results controls (above the results table):
  - `Show Needs Action` / `Show All` (filters to files still needing action)
  - `Show Failures` / `Show All` (enabled after a completed `Fix Offsets` pass)

Non-MP4 Scanner behavior
- Tools menu opens a separate window scene:
  - Scene is `Window("Scan for Non-MP4 Files", id: "nonMP4Scanner")`
- Scan behavior:
  - Input picker selects a root folder.
  - Scan is recursive (includes subfolders).
  - File ordering is stable natural sort by relative path (`localizedStandardCompare`).
  - Results include common video extensions; non-`mp4` entries are flagged.
- UI behavior:
  - Toolbar actions: `Choose Folder...`, `Send Flagged to Main`, `Export Flagged...`, `Scan`, `Stop` (while scanning).
  - Folder section has an inline `Open` button to the left of `Input Folder` to reveal the selected folder in Finder.
  - Scan Results control: `Show Flagged` / `Show All`.

MP4 Validation behavior
- Tools menu opens a separate window scene:
  - Scene is `Window("Validate MP4 Files", id: "mp4Validation")`
- Scan behavior:
  - Input picker selects a root folder.
  - Scan is recursive (includes subfolders), MP4 files only.
  - File ordering is stable natural sort by relative path (`localizedStandardCompare`).
  - Validation flags files with compatibility issues (AV1/DTS when ffprobe is available, or non-playable assets).
- UI behavior:
  - Toolbar actions: `Choose Folder...`, `Send Flagged to Main`, `Export Flagged...`, `Validate`, `Stop` (while validating).
  - Folder section has an inline `Open` button to the left of `Input Folder` to reveal the selected folder in Finder.
  - Scan Results control: `Show Flagged` / `Show All`.

Subtitle Merger behavior
- Tools menu opens a separate window scene:
  - Scene is `Window("Subtitle Merger", id: "subtitleMuxer")`
- Output naming behavior:
  - Output filename is auto-filled directly from the selected MP4 input filename.
  - TV patterns use `Show Name - S01E02.mp4`.
  - If a TV show title includes a year token, keep it in parentheses: `Show Name (2024) - S01E02.mp4`.
  - Movie patterns use `Title (Year).mp4`.
  - If custom naming cannot be derived, fallback is `<original_file_name>_remux.mp4`.
  - If resolved output path matches the selected input MP4 path, rename the original input to `<name>_original(.N).mp4` before muxing so output can be written using the intended final filename.
- UI behavior:
  - Rename is inline with the Output section (no separate rename card, no preview/apply sub-flow).
  - `Output File` remains user-editable after auto-fill.

Splitting
- Split uses `-c copy` with `-ss` / `-to` for part 1, then `-ss` for part 2.
- Split button only enabled when:
  - Output folder selected
  - At least one item selected
  - Not scanning/splitting

Main app automatic rename behavior
- Main Settings includes `Automatic Rename` toggle for encoder/remuxer workflow.
- When enabled, output filenames in the main processing flow are auto-normalized for supported TV/movie patterns.
- Conflict checks in the main workflow should use the same resolved output filename logic used at processing time.

Rename logic
- Optional “Rename Files” setting (persisted).
- If enabled:
  - Derive prefix/suffix and starting number from the first selected item only.
  - Output names are sequential across all selected items (no re-parsing per file).
  - Supports:
    - Range patterns (e.g., `E01-E02`, `S01E01-E02`)
    - Single-episode patterns (e.g., `Show - S01E01`)
  - Keeps original prefix/suffix for all outputs.
  - Parsing prefers `E`-style prefixes so `S04E08` is treated as prefix `S04E` + number `08` (padLength = 2), avoiding `E008`/`E010`.
- Preview line in list shows the two output names per item.

Persistence
- Video Splitter settings are stored in AppStorage:
  - videoSplitterBlackMinDuration
  - videoSplitterBlackThresholdSeconds
  - videoSplitterPicThreshold
  - videoSplitterHalfwayScanEnabled
  - videoSplitterHalfwayWindowMinutes
  - videoSplitterRenameFiles

Notes
- Prefer non-modal UI warnings for scan issues (red text in window).
- Keep output ordering stable and consistent with input order.
