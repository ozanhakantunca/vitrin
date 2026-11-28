# Manual testing

Grant Accessibility and Screen Recording before testing. Each step below includes its expected result.

## Install/permissions
- Install and launch Vitrin; the menu bar icon appears, and permission prompts lead to the appropriate System Settings panes.
- Grant both permissions and reopen if requested; window switching and thumbnails work.

## F1 switcher core
- Hold ⌥ and press Tab; windows appear in MRU order with the previous window selected.
- Press Tab, Shift-Tab and arrow keys; selection moves accordingly. Release ⌥; the selected window gains focus.
- Open the current-app shortcut; only windows of that app appear.

## F1 actions
- On a selected window try W, M, F, H and Q; respectively the window closes, minimizes, toggles fullscreen, the app hides, or the app quits.
- Press Esc; the switcher closes without changing focus.

## F2 search
- Type a title or app name; results filter live and best matches appear first. Type multiple words; each word must match. Clear the query; all windows return in MRU order.
- Search Turkish text without accents or with dotted/dotless i; corresponding windows match.

## F2 styles and preview
- Select thumbnails, app icons and titles styles; each switcher uses the chosen presentation.
- Invoke full-size preview on a selection; the selected window is previewed and the switcher remains usable.

## F2 settings
- Change settings and add multiple shortcut profiles; changes persist after reopening Settings and affect the switcher.

## Exceptions
- Add an app exception and open the switcher; its windows follow the configured exception. Remove it; normal behavior returns.

## Quit apps when their last window closes
Turn on Settings → General → Quit apps when their last window closes. Use TextEdit (or another Dock app) unless noted.
- Open two windows and close both with the red button or ⌘W; about a second after the last one closes, the app quits. Closing only the first one keeps it running.
- Type in a document and close it, choosing Cancel in the save prompt; the window stays and the app keeps running. Close it again and choose Don't Save; the app quits.
- With one window: minimize it, hide the app (⌘H), make the window fullscreen, and switch desktops; the app keeps running each time. Move the window to another desktop, then close a second window on the current desktop; the app keeps running.
- Launch an app that starts without a window, or with only an open panel (TextEdit with iCloud Drive: press Cancel); the app keeps running. Close a window that can't be minimized, such as About or most Settings windows, while no document window is open; the app keeps running.
- `swift scripts/vitrin-debug.swift dump` lists `standard=true` for the windows that count (minimized windows may show `standard=false` but still count).
- Close a Finder window, and the window of a menu-bar app; both keep running.
- In Safari, close the second-to-last tab of a window, and switch tabs; Safari keeps running. Close the last window; Safari quits.
- Add an app to Exceptions with Keep running ticked and close its last window; it keeps running. Untick it, open a window and close it; the app quits.
- Quit an app with ⌘Q, or with Q in the switcher; it quits once, with no extra prompt.
- Turn the setting off; closing the last window leaves the app running again.

## ⌘Tab takeover/restore
- Enable ⌘Tab takeover; ⌘Tab opens Vitrin. Disable it or quit Vitrin; the system switcher works again.

## Config file live reload
- Edit `~/.config/vitrin/config.json` externally; valid changes appear without restarting. Invalid JSON reports an error and the last usable settings remain active.

## Multi-display
- Open windows on multiple displays and invoke the switcher; windows are listed and selecting one focuses it on its display.

## Fullscreen Spaces
- Open a fullscreen window on another Space; switching to it changes Space and focuses the window.

## Performance
- Open many windows and type rapidly; filtering and navigation remain responsive.
- Enable debug commands with `defaults write io.github.ozanhakantunca.vitrin debugCommands -bool true`. Run `swift scripts/vitrin-debug.swift open all-windows`, or substitute `next`, `previous`, `confirm`, `cancel`, `demo 12`, or `dump`; each command performs its named action. Dump writes `$(getconf DARWIN_USER_TEMP_DIR)vitrin-dump.txt`. Any local process can send these commands while they are enabled, so turn them off afterwards: `defaults delete io.github.ozanhakantunca.vitrin debugCommands`, then restart Vitrin.
