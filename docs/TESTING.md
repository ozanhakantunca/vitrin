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
- Enable debug commands with `defaults write io.github.ozanhakantunca.vitrin debugCommands -bool true`. Run `swift scripts/vitrin-debug.swift open all-windows`, or substitute `next`, `previous`, `confirm`, `cancel`, `demo 12`, or `dump`; each command performs its named action. Dump writes `$(getconf DARWIN_USER_TEMP_DIR)vitrin-dump.txt`.
