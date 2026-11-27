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
- **Task View** — a full-screen overview of all windows, like Windows' Win+Tab, with a desktop strip
  to switch desktops (Spaces).
- **Type to search** — fuzzy matching on app names and window titles, Turkish characters included.
- **Act on windows** without leaving the switcher: close, minimize, fullscreen, hide, quit.
- **Unlimited shortcuts**, each with its own filter (all windows, current app, current desktop…)
  and style.
- **Optional ⌘Tab takeover**, restored automatically when Vitrin quits.
- **App exceptions** so VMs and remote desktops still receive Alt+Tab.
- **Optional: quit apps when their last window closes**, as on Windows.
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

Vitrin opens at login by default; turn it off in **Settings → General → Launch at login**.

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
open until you pick a window. The strip at the bottom shows your desktops: press ↓ from the last row
(or click) to reach it, ←/→ to choose and Return to switch. Switching focuses the desktop's most recent
window; an empty desktop is switched to directly.

### Coming from Windows

A Windows keyboard in macOS mode sends **Alt as ⌥** and the **Windows key as ⌘**, so:

- **Alt+Tab** works as you expect, and **Ctrl+W** closes the selected window while Alt is still held.
- **Win+Tab** opens Task View once it is enabled, and its desktop strip switches desktops.

If a key remapper such as Karabiner-Elements has its own rule for Win+Tab (⌘Tab), remove that rule —
it catches the key before Vitrin does.

On macOS, closing an app's last window leaves the app running in the Dock. Turn on **Settings → General
→ Quit apps when their last window closes** to quit it instead, as Windows does. Vitrin quits the app
the way ⌘Q does, so unsaved changes are still asked about. Minimizing, hiding (⌘H), fullscreen and
switching desktops don't count, and windows on other desktops still keep an app open. Vitrin also
waits about a second before quitting an app, so a window that reopens right away keeps the app
running. Dialogs, open and save panels, and windows that can't be minimized (About, most Settings
windows) don't count. It never quits an app that had no window open to begin with, Finder, or
menu-bar-only apps.
To keep a particular app running, give it a **Keep running** exception (see
[App exceptions](#app-exceptions)).

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

Keys you leave out keep their defaults, so a config file only needs the settings you change.

### App exceptions

An exception changes how Vitrin treats one app. Add one in **Settings → Exceptions** with **Add
running app** or **Choose app…**, then set any of these options for it:

| Option | `config.json` key | Effect |
|---|---|---|
| Hide from switcher | `"hide": "always"` | The app's windows never appear in the switcher (default `"never"`). |
| Ignore shortcuts | `"ignoreShortcutsWhenFrontmost": true` | While the app is in front, Vitrin's shortcuts go to the app instead. Use it for VMs and remote desktops. |
| Keep running | `"keepRunningWhenLastWindowCloses": true` | The app keeps running when its last window closes, even with the quit option on. |

In `config.json`, each exception names the app by its bundle identifier. Only `bundleIdentifier` is
required; options you leave out are off. To find an app's bundle identifier:

```sh
osascript -e 'id of app "Terminal"'    # com.apple.Terminal
```

Some common setups:

```json
{
  "quitAppsWhenLastWindowCloses": true,
  "appExceptions": [
    { "bundleIdentifier": "com.utmapp.UTM", "ignoreShortcutsWhenFrontmost": true },
    { "bundleIdentifier": "com.apple.Terminal", "keepRunningWhenLastWindowCloses": true },
    { "bundleIdentifier": "com.apple.Music", "keepRunningWhenLastWindowCloses": true, "hide": "always" }
  ]
}
```

- **UTM:** a virtual machine that receives Alt+Tab itself.
- **Terminal:** stays open after its last window closes. Use this for terminals, editors and agent apps
  whose sessions or background work should survive.
- **Music:** keeps playing without a window and stays out of the switcher.

Vitrin ships built-in exceptions for common VM, remote-desktop and game-streaming apps. If you write an
`appExceptions` list yourself, it replaces those built-in exceptions. Copy the ones you need from
**Settings → Exceptions** before you edit the file, or add your apps in Settings instead.

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
