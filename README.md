# Memopila

Native macOS clipboard manager.

Design and v1 scope: [docs/PLAN.md](docs/PLAN.md).

## Status

Phase 1 shell. Menu bar app with a history panel on ⌥⌘V, capture with privacy markers, per-app identity and format rules, pause / skip next copy, Restore and Copy As text actions, and a Diagnostics window for the Phase 1 spikes. **History is kept in memory only** (at most 50 items / 64 MB) until the SwiftData store lands in Phase 2.

## Build and run

Requirements: macOS 15.4 or later, Xcode 26 or later.

1. Open `App/Memopila.xcodeproj`.
2. Target **Memopila** → *Signing & Capabilities* → choose your **Team** (a free Apple ID personal team is enough). Use a stable Apple Development identity rather than *Sign to Run Locally*: macOS ties the clipboard access choice to the app's signature.
3. Run. Memopila appears in the menu bar.
4. Quit Pasta first, or pick another shortcut in Settings — only one app can hold ⌥⌘V.
5. On first launch choose **Enable capture** (menu bar menu or the panel banner). If macOS asks about clipboard access, allow it; if capture stays paused, open System Settings → Privacy & Security and set Memopila to *Always Allow*.

Menu bar → **Diagnostics…** shows the clipboard access state and lets you probe single pasteboard calls (`changeCount`, `types`, content read) to see which ones trigger the system alert — the Phase 1 spike questions in PLAN §3.1. **Copy report** puts the results on the clipboard.

## Tests

The platform-independent core builds and tests on macOS and Linux:

```sh
swift test --package-path Packages/MemopilaCore
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux and macOS and builds the app with Xcode.

## Layout

- `Packages/MemopilaCore` — capture decisions, canonical hashing, format policy, retention, text tools (no AppKit).
- `App/` — the macOS app (SwiftUI + AppKit); sources live in `App/Memopila`, picked up by the Xcode project automatically.
- `docs/PLAN.md` — the design.

**Privacy note:** Per-app settings such as *Don't save* identify the source app by the self-reported `org.nspasteboard.source` pasteboard marker when present, otherwise by the frontmost app at copy time. Neither is authenticated—another app can claim a different bundle ID, and a copy made in the background can be attributed to the wrong app. This is a convenience filter, not a security boundary; *Strict* mode skips copies without a valid marker whenever an app is set to *Don't save*. For one-off secrets use *Pause* or *Skip next copy*. History is stored locally and is not encrypted. Other clipboard managers may also compete for global hotkeys or pasteboard access policy.
