# Memopila

Native macOS clipboard manager.

Design and v1 scope: [docs/PLAN.md](docs/PLAN.md).

**Privacy note:** App exclusions rely on the self-reported `org.nspasteboard.source` pasteboard marker. With exclusions enabled, copies without a valid marker are skipped. The marker is not authenticated—another app can claim a different bundle ID. This is a convenience filter, not a security boundary. Other clipboard managers may also compete for global hotkeys or pasteboard access policy.
