# Memopila

Native macOS clipboard manager.

Design and v1 scope: [docs/PLAN.md](docs/PLAN.md).

**Privacy note:** Per-app settings such as *Don't save* identify the source app by the self-reported `org.nspasteboard.source` pasteboard marker when present, otherwise by the frontmost app at copy time. Neither is authenticated—another app can claim a different bundle ID, and a copy made in the background can be attributed to the wrong app. This is a convenience filter, not a security boundary; *Strict* mode skips copies without a valid marker whenever an app is set to *Don't save*. For one-off secrets use *Pause* or *Skip next copy*. History is stored locally and is not encrypted. Other clipboard managers may also compete for global hotkeys or pasteboard access policy.
