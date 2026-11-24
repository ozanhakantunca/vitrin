# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.1] - 2026-11-24

### Security
- The app is signed with the hardened runtime: other processes can no longer load their own code into
  Vitrin and use its Accessibility and Screen Recording access.
- The `vitrin` command-line tool talks to the app over a private socket that only Vitrin's own binary
  can use; other processes could previously read window titles through it.
- Update links are only followed to github.com. CI actions are pinned to commit hashes.

### Changed
- Thumbnails load up to four at a time, and thumbnails of closed windows are dropped from memory.

### Fixed
- Vitrin now opens at login by default (turned on once; turning it off is respected), and the
  `launchAtLogin` config setting is applied when edited.
- A syntax error saved while editing `config.json` no longer moves the file away and resets every
  setting; the previous settings stay active until the file is valid again.
- The switcher no longer stays open when a modifier release was missed while macOS had paused
  Vitrin's keyboard event tap.
- An app could show another app's icon after macOS reused its process id.

## [0.2.0] - 2026-11-19

### Added
- Task View desktop strip: see every desktop (Space) of the screen with its apps and switch to one with
  the keyboard (↓, ←/→, Return) or a click. Toggle: Settings → Shortcuts → "Show desktops in Task View".

## [0.1.0] - 2026-11-19

First public release.

### Added

- Window switching across all desktops (Spaces), including minimized windows and hidden apps, with live thumbnails.
- Thumbnail, app-icon and title-list styles; full-screen Task View; automatic sizing.
- Type-to-search with fuzzy, Turkish-aware matching.
- Window actions inside the switcher (close, minimize, fullscreen, hide, quit) with ⌃ or ⌘.
- Unlimited shortcut profiles with per-profile filters and styles; optional ⌘Tab takeover with automatic restore.
- App exceptions for VMs and remote desktops.
- Settings window and a live-reloaded `~/.config/vitrin/config.json`.
- `vitrin` command-line tool (`list`, `focus`, `show`).
- Optional three-finger trackpad gesture, update notifications, English and Turkish interface.
