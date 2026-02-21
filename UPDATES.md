# UPDATES.md

This guide explains how to add Zippy-style "Check for Updates" to another macOS Swift app.

## What This Uses

- GitHub releases API (with tags fallback) to detect the newest version and fetch release notes.
- One Info.plist value to configure the app:
  - `UpdateCheckReleasesURL`
- A reusable helper:
  - `AppUpdateCenter`
- A SwiftUI overlay view:
  - `UpdateAvailableOverlayView`

## Files To Copy

From this project, copy:

- `Zippy/Logic/AppUpdateCenter.swift`
- `Zippy/UI/UpdateAvailableOverlayView.swift` (or equivalent)

You can rename it or keep the same filename/class name.

## Info.plist Setup

Add this key to your app's `Info.plist`:

```xml
<key>UpdateCheckReleasesURL</key>
<string>https://github.com/OWNER/REPO/releases</string>
```

Example:

```xml
<key>UpdateCheckReleasesURL</key>
<string>https://github.com/georgebabichev/Zippy/releases</string>
```

`AppUpdateCenter` will parse `OWNER/REPO` from this URL and check tags from:

`https://api.github.com/repos/OWNER/REPO/tags`

It will also check releases from:

`https://api.github.com/repos/OWNER/REPO/releases`

## Launch-Time Check

Call update check from app initialization, not from a SwiftUI view lifecycle callback.

Use one of these app-level entry points:
- App `init()` (SwiftUI app struct)
- App delegate `applicationDidFinishLaunching`

Do **not** run launch update checks from `ContentView.onAppear` (or any view `.onAppear`), because view lifecycle callbacks can be triggered during UI recomposition and may cause unnecessary churn.

In your app delegate (or app lifecycle hook):

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
}
```

Current Zippy reference:

- `Zippy/Logic/AppTerminationDelegate.swift`

Behavior:

- Automatic checks are quiet unless a newer version is found.
- Automatic checks should be scheduled from app init / launch hooks only, never from view `.onAppear`.

## App Menu Integration

Add a menu item under the App menu ("About" section is standard macOS placement):

```swift
Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle") {
    AppUpdateCenter.shared.checkForUpdates(trigger: .manual)
}
```

Current Zippy reference:

- `Zippy/UI/AppCommands.swift`

Behavior:

- Manual checks always show a result alert (up-to-date, error, or update available).
 - Manual checks show alerts for up-to-date/error.
 - When an update is found, show the update overlay (not an alert).

## Update Overlay UI

When an update is available, draw a modal-like SwiftUI overlay using shared `AppUpdateCenter` state.

State contract:
- `AppUpdateCenter.availableUpdate` is non-`nil` when overlay should be shown.
- `availableUpdate` contains:
  - app name
  - current version
  - latest version
  - summary message
  - release notes (optional)
  - release URL (optional)

Placement:
- Add an `.overlay` at app content level (for example in `ContentView`) and render only when `availableUpdate` is non-`nil`.
- Example:

```swift
.overlay {
    if let update = updateCenter.availableUpdate {
        UpdateAvailableOverlayView(
            update: update,
            onLater: { updateCenter.dismissAvailableUpdate() },
            onDownload: { updateCenter.openAvailableUpdateDownloadPage() }
        )
    }
}
```

Visual structure:
- Full-window dim backdrop (`Color.black.opacity(0.25)`).
- Centered rounded card.
- Header:
  - "Update Available"
  - App name
  - `current → latest` version line
  - short message
- "Release Notes" section:
  - Scrollable text area
  - If notes are missing, show fallback text.
- Footer actions:
  - `Later` dismisses overlay.
  - `Open Download Page` opens release URL when available.
  - If URL is missing, show `Close` as primary action.

Interaction behavior:
- Opening download page should also dismiss overlay.
- Launch-time checks remain quiet unless an update is found.

## About View Integration (Optional but Recommended)

Use shared state in About UI:

```swift
@ObservedObject private var updateCenter = AppUpdateCenter.shared
```

Add button:

```swift
Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle") {
    updateCenter.checkForUpdates(trigger: .manual)
}
.disabled(updateCenter.isChecking)
```

Optional status text:

```swift
if let lastStatusMessage = updateCenter.lastStatusMessage {
    Text(lastStatusMessage)
}
```

Current Zippy reference:

- `Zippy/UI/AboutView.swift`

## Versioning Expectations

- Your app version should be in `CFBundleShortVersionString`.
- GitHub tags should follow numeric style (examples: `1.0.0`, `v1.2.3`).
- The comparator is tolerant of a leading `v`.

## Common Pitfalls

- Missing `UpdateCheckReleasesURL` key: update check will be treated as not configured.
- Non-GitHub URL: owner/repo parsing will fail by design.
- No releases/tags in repo: manual checks show a friendly error.
- Running launch checks from `.onAppear`: can cause unnecessary UI churn.

## Reuse Checklist

1. Copy `AppUpdateCenter.swift`.
2. Add `UpdateCheckReleasesURL` to `Info.plist`.
3. Wire launch check (`automaticLaunch`) from app init/app delegate (not view `.onAppear`).
4. Add App menu action (`manual`).
5. Add update overlay wiring at app content level.
6. Add About button + status text (optional).
