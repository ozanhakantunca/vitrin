# Backlog

Ideas and known gaps. Contributions welcome — open an issue before starting on a larger item.

## Planned
- **Switch desktops (Spaces) from the switcher** — jump to another desktop from Alt+Tab or Task View,
  not only to a window on it.

## Known gaps
- If Vitrin is force-killed or crashes while it has taken over ⌘Tab, macOS's ⌘Tab stays off until
  Vitrin is launched again (a normal quit, SIGTERM or SIGINT restores it).
- App exceptions match bundle ids exactly; Parallels Coherence apps (`com.parallels.winapp.*`) would
  need prefix matching. Some built-in exception bundle ids are unverified (`AppException.builtInDefaults`).
- Users whose config already has `"appExceptions": []` don't get the built-in VM / remote-desktop
  exceptions; a "restore default exceptions" button in Settings would cover it.
- Task View: the small app icon sits at the thumbnail area's left edge when no thumbnail is available.
- The trackpad gesture has not been tested on many devices yet.
- Never auto-save a config written by a newer Vitrin (`ConfigLoadResult.isFromNewerVersion`): it would
  strip fields that version added.

## Possible additions
- More private-API fallbacks: `SLSSpaceSetFrontPSN` (focus bleeding across Spaces),
  `CGSHWCaptureWindowList` (thumbnail fallback), SkyLight window-event notifications.
- Entries for apps with no open window (AltTab's "show apps with no open window").
- Optional `XDG_CONFIG_HOME` support (`ConfigStore.defaultURL`).

## Build and CI
- `scripts/build-app.sh` passes `--build-system native`, which Swift 6.4 marks deprecated. Switch to the
  default backend once CI's Swift version supports it, and re-verify universal builds.
- `VITRIN_SKIP_WINDOWSERVER_TESTS=1` skips tests that need a logged-in WindowServer session, should a CI
  runner lack one.
