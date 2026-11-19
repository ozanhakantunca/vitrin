<p align="center">
  <img src="Resources/AppIcon/Vitrin.png" width="128" alt="Vitrin icon">
</p>

<h1 align="center">Vitrin</h1>

<p align="center">
  A free, open-source window switcher for macOS — Alt+Tab the way Windows and Linux do it.
  <br>
  <a href="README.tr.md">Türkçe</a> ·
  <a href="https://github.com/ozanhakantunca/vitrin/releases/latest">Download</a>
</p>

---

macOS's ⌘Tab switches between apps. Vitrin switches between **windows**: every window, on every
desktop, with a live preview of each one. Everything is free; there is no paid tier.

## Features

- **Every window** — windows on other desktops (Spaces), minimized windows and hidden apps.
- **Live thumbnails**, or a compact app-icon or title-list style.
- **Task View** — a full-screen overview of all windows, like Windows' Win+Tab.
- **Type to search** — fuzzy matching on app names and window titles, Turkish characters included.
- **Act on windows** without leaving the switcher: close, minimize, fullscreen, hide, quit.
- **Unlimited shortcuts**, each with its own filter (all windows, current app, current desktop…)
  and style.
- **Optional ⌘Tab takeover**, restored automatically when Vitrin quits.
- **App exceptions** so VMs and remote desktops still receive Alt+Tab.
- **Plain-text config** at `~/.config/vitrin/config.json`, reloaded live — dotfiles friendly.
- **Command-line tool**: `vitrin list`, `vitrin focus`, `vitrin show`.
- Optional three-finger trackpad swipe, update notifications, English and Turkish interface.

Requires macOS 13 Ventura or later, on Apple silicon or Intel.

## Install

### Download (DMG)

1. Download `Vitrin-x.y.z.dmg` from the [latest release](https://github.com/ozanhakantunca/vitrin/releases/latest)
   and drag **Vitrin** into **Applications**.
2. Vitrin is not notarized by Apple, so the first launch is blocked. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Vitrin.app
   ```

### Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ozanhakantunca/vitrin
cd vitrin
./scripts/create-signing-cert.sh   # once: a local signing identity, so permissions survive rebuilds
./scripts/install.sh --with-cli    # builds, installs to /Applications and links the `vitrin` command
```

### Permissions

On first launch Vitrin asks for:

- **Accessibility** (required) — to list, focus and control windows.
- **Screen Recording** (optional) — for thumbnails. Without it, app icons are shown instead.

## Usage

| Keys | Action |
|---|---|
| ⌥Tab | Open the switcher / next window. Release ⌥ to switch. |
| ⌥⇧Tab | Previous window |
| ⌥ + key above Tab | Windows of the current app only |
| Arrow keys | Move the selection |
| Return | Switch to the selection |
| Esc | Cancel |
| Type letters | Search |
| ⌃ or ⌘ + W / M / F / H / Q | Close / minimize / fullscreen / hide app / quit app |
| Delete (⌦) | Close the selected window |

A quick ⌥Tab tap jumps straight back to the previous window without showing the panel.

**Task View** is off by default. Turn it on in **Settings → Shortcuts**: it opens with ⌘Tab and stays
open until you pick a window.

### Coming from Windows

A Windows keyboard in macOS mode sends **Alt as ⌥** and the **Windows key as ⌘**, so:

- **Alt+Tab** works as you expect, and **Ctrl+W** closes the selected window while Alt is still held.
- **Win+Tab** opens Task View once it is enabled.

If a key remapper such as Karabiner-Elements has its own rule for Win+Tab (⌘Tab), remove that rule —
it catches the key before Vitrin does.

## Configuration

Everything is available in the Settings window (menu-bar icon → Settings). The same settings live in
`~/.config/vitrin/config.json`, and edits to that file apply immediately. For example, a ⌃Tab shortcut
for the current app's windows:

```json
{
  "schemaVersion": 1,
  "profiles": [{
    "id": "my-windows", "name": "My windows", "enabled": true,
    "trigger": "control+tab", "filters": {"apps": "activeApp"},
    "style": "thumbnails", "size": "auto", "onModifierRelease": "focusSelection"
  }]
}
```

A `profiles` list replaces the built-in shortcuts, so include every shortcut you want to keep.

## Command line

```sh
vitrin list            # windows in most-recently-used order
vitrin focus <id>      # focus a window by id
vitrin show [profile]  # open the switcher
```

## Troubleshooting

- **Vitrin keeps asking for Accessibility although the switch is on.** The permission belongs to an
  older build with a different signature. Reset it, relaunch Vitrin and switch it on again:
  `tccutil reset Accessibility io.github.ozanhakantunca.vitrin`
- **A shortcut does nothing.** Check that no other app (another switcher, a key remapper) uses it.

## Uninstall

Quit Vitrin and delete it from Applications, or from a source checkout run `./scripts/uninstall.sh`
(`--purge-config` also removes `~/.config/vitrin`).

## Compared with AltTab

Vitrin is inspired by [AltTab](https://github.com/lwouis/alt-tab-macos) and is not affiliated with it.
Search, the icon and title styles, automatic sizing and multiple shortcuts are part of AltTab's paid
tier; in Vitrin they are free, along with Task View.

## Contributing

`swift build` and `swift test` build and test the project; `scripts/build-app.sh` makes the app bundle.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE)
