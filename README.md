# Memopila

Native macOS clipboard manager.

Design and v1 scope: [docs/PLAN.md](docs/PLAN.md).

## Status

All v1 features of the plan are implemented and build in CI; they have not yet been run on a real Mac, so expect rough edges until the Phase 1 spikes (PLAN §10) are checked on device.

- Menu bar app; history panel on ⌥⌘V (non-activating, pin to keep it open, frame remembered per display).
- History on disk (SwiftData, payloads in external storage); RAM holds only the visible cards and a 24 MB thumbnail cache, dropped 10 s after the panel closes.
- Pasta-style layout: sidebar with History, Favorites, Apps and Collections, a filter bar (kind, period) and search over text, titles, text in images, app names, source pages and file names, with matches marked on the cards.
- Red *Current — not saved* card for oversized, unsupported or failed copies, with *Save Anyway* and per-app quick fixes; format rules (keep / skip types per app, e.g. for Photoshop) and a clipboard inspector.
- Per-app settings: *Don't save*, *Delete after*, size limit, text recognition, source page; quick actions on every card and app with Undo.
- Pause capture, *Skip next copy* (menu, optional hotkeys).
- *Edit Record*: one window to look at and edit a record — syntax highlighting while you type, line numbers for code, invisible characters, *Changes…* against the saved text, the standard *Save / Don’t Save / Cancel* sheet instead of lost edits, *Copied from <page>*, text recognized in images (Vision, on device), copied as a new card.
- Text actions, titles, favorites, collections; *Duplicate As*; ⌘K actions panel; full keyboard map (PLAN §8.3).
- The card the clipboard holds has a thin green line (inside the blue selection border when it is also selected); a double-click makes another record the clipboard content and takes you back to your app. Optional paste after copying (Accessibility), launch at login, tooltips on every control, English and Russian.

## Build and run

Requirements: macOS 15.4 or later, Xcode 26 or later.

1. Open `App/Memopila.xcodeproj`.
2. Target **Memopila** → *Signing & Capabilities* → choose your **Team** (a free Apple ID personal team is enough). Use a stable Apple Development identity rather than *Sign to Run Locally*: macOS ties the clipboard access choice to the app's signature.
3. Run. The panel opens and Memopila appears in the menu bar. A click on the icon opens the panel; right-click shows a short menu. If the icon is missing, the menu bar is full: on a Mac with a notch the icons that do not fit are hidden. ⌥⌘V and opening Memopila again from Finder or Spotlight still open the panel; Diagnostics shows where the icon is.
4. Quit Pasta first, or pick another shortcut in Settings — only one app can hold ⌥⌘V.
5. On first launch choose **Enable capture** (menu bar menu or the panel banner). If macOS asks about clipboard access, allow it; if capture stays paused, open System Settings → Privacy & Security and set Memopila to *Always Allow*.

Settings → **Apps** and the **Rules for <App> ▸** submenu on each card hold per-app settings; Settings → **Formats** has the size limit, global format rules and **Inspect** for the current clipboard.

Gear menu (or right-click on the menu bar icon) → **Diagnostics…** shows the clipboard access state and lets you probe single pasteboard calls (`changeCount`, `types`, content read) to see which ones trigger the system alert — the Phase 1 spike questions in PLAN §3.1. **Copy report** puts the results on the clipboard.

## Tests

The platform-independent core builds and tests on macOS and Linux; the services package (store, pasteboard, thumbnails, text recognition) on macOS:

```sh
swift test --package-path Packages/MemopilaCore
swift test --package-path Packages/MemopilaServices
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux and macOS, the services tests on macOS, and builds the app with Xcode.

## Layout

- `Packages/MemopilaCore` — capture decisions, canonical hashing, format policy, retention, text tools, code highlighting (no AppKit).
- `Packages/MemopilaServices` — SwiftData store, pasteboard reader and writer, thumbnails, text recognition (macOS).
- `App/` — the macOS app (SwiftUI + AppKit); sources live in `App/Memopila`, picked up by the Xcode project automatically. Settings are kept in `UserDefaults`, history in `~/Library/Application Support/Memopila/History.store`.
- `docs/PLAN.md` — the design.

**Privacy note:** Per-app settings such as *Don't save* identify the source app by the self-reported `org.nspasteboard.source` pasteboard marker when present, otherwise by the frontmost app at copy time. Neither is authenticated—another app can claim a different bundle ID, and a copy made in the background can be attributed to the wrong app. This is a convenience filter, not a security boundary; *Strict* mode skips copies without a valid marker whenever an app is set to *Don't save*. For one-off secrets use *Pause* or *Skip next copy*. History is stored locally and is not encrypted. Other clipboard managers may also compete for global hotkeys or pasteboard access policy.
