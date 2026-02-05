AGENTS.md

Project: MP4 Tool (macOS SwiftUI)

Overview
- Main window: `MP4 Tool/Views/ContentView.swift`
- Settings panel: `MP4 Tool/Views/SettingsView.swift` + `MP4 Tool/Views/SettingsToggleSection.swift`
- Video Splitter window: `MP4 Tool/Views/VideoSplitterView.swift`
- Video Splitter logic: `MP4 Tool/Logic/VideoSplitterViewModel.swift`
- Offset Checker window: `MP4 Tool/Views/OffsetStartCheckerView.swift`
- Offset Checker logic: `MP4 Tool/Logic/OffsetStartCheckerViewModel.swift`
- App scenes/menus: `MP4 Tool/MP4_ToolApp.swift`

UI conventions
- Settings panels use GroupBox with slightly smaller type, compact spacing.
- Settings row labels use `.subheadline`; controls are compact (`.controlSize(.small)`).
- Content should be top-aligned within windows (`.frame(..., alignment: .topLeading)`).
- Video Splitter uses:
  - Folder pickers for input/output
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
  - Replacement is in-place via temp file + atomic replace (ffmpeg does not write directly to the same input path).
  - Includes progress + Stop; cancel terminates in-flight process.

Splitting
- Split uses `-c copy` with `-ss` / `-to` for part 1, then `-ss` for part 2.
- Split button only enabled when:
  - Output folder selected
  - At least one item selected
  - Not scanning/splitting

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
