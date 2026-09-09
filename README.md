# aside.

**The logo is one object: the word on a paper card, with the green drawer pulled
out over its right edge.** No trailing period. The drawer is the device, and it is
the same shape in the app icon and in the logo, just at different widths. The
macOS app bundle is "Aside".

A pull tab on the right edge of the screen. Click it and a notepad slides out
over whatever you are in. It can live on any attached display. Notes are plain markdown files in the
Obsidian vault, so everything you jot shows up in Sirius Vault search.

## Build and run

```
./build.sh
open build/Aside.app
```

Command Line Tools only. No Xcode, no Homebrew, no dependencies.

## Using it

| Action | How |
|---|---|
| Open / close | Click the tab, or press Escape while open |
| Move the tab | Drag it anywhere, including onto another display |
| Pick a display | The "..." menu, under "Show On" |
| New note | The pencil icon |
| Switch notes | The list icon, then click a note |
| Delete a note | Right-click it in the list, or the "..." menu (goes to Trash) |
| Open at login | The "..." menu |
| Quit | The "..." menu |

The first line of a note is its title, Apple Notes style, and it becomes the
filename. Retitling renames the file.

## Brand

| File | What it is |
|---|---|
| `brand/lockup.svg` | The primary logo. Use this wherever the word fits. |
| `brand/mark.svg` | The mark alone, for favicons and tight spaces. |
| `brand/icon.svg` | App icon source. |
| `brand/Aside.icns` | Built icon, copied into the bundle by `build.sh`. |
| `brand/aside-brand.svg` | The brand sheet. |

Rebuild the icon after editing `icon.svg` with `brand/build-icon.sh`.

| | |
|---|---|
| Ink | `#12110F` |
| Graphite | `#1B1916` |
| Ledger (accent) | `#3FA47C` |
| Ledger Deep | `#2A7256` |
| Paper | `#F6F2EA` |
| Ash | `#8A857D` |

Ledger is the only saturated color. Inside the app, selection deliberately stays
on the macOS system accent color rather than the brand color: overriding the
user's own accent is not native behavior.

## Displays

Drag the tab and it follows your pointer, re-pinning to the right edge of
whichever display the pointer is on. On this machine the ultrawide sits above
the built-in screen, so dragging the tab up moves it to the ultrawide. The
"..." menu has an explicit "Show On" picker for the same thing.

The choice is remembered by display id, then by display name if the id changed
across a reboot. Unplugging a display parks the tab on the primary screen
without forgetting the preference, so plugging back in restores it.

## Where notes live

`~/Desktop/claude-workspace/Sirius Vault/aside/*.md`

To point it somewhere else:

```
defaults write com.espyagency.aside notesDirectory ~/some/other/folder
```

Edits made in Obsidian are picked up the next time the drawer opens.

## Notes on the build

- Automatic dash substitution is off, so typing `--` never becomes an em dash
  in a vault file. Smart quotes are off too, for the same reason.
- The window is a full-height invisible strip on the right edge. Only the tab
  (closed) or the panel (open) accepts clicks; everything else passes straight
  through to the app underneath. `tools/tests.swift` covers this.
- Nothing moves or resizes the window. The slide is Core Animation on the
  subviews, using Apple's standard easing.

## Tests

```
swiftc -target arm64-apple-macos14.0 -o build/snapshot \
  Sources/*.swift tools/tests.swift tools/main.swift
./build/snapshot test                      # hit testing + file naming
./build/snapshot preview.png dark list     # render the UI offscreen to a PNG
```

`tools/` is development only and is not part of the app bundle.
