# aside.

**The logo is one object: the word on a paper card, with the green drawer pulled
out over its right edge.** No trailing period. The drawer is the device, and it is
the same shape in the app icon and in the logo, just at different widths. The
macOS app bundle is "Aside".

A pull tab on the right edge of the screen. Click it and a notepad slides out
over whatever you are in. It can live on any attached display. Notes are plain markdown files in the
notes vault, so everything you jot is searchable alongside the rest of your
writing.

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
| Search | The list icon, then type |
| Resize | Drag the drawer's inboard edge |
| Switch notes | The list icon, then click a note |
| Delete a note | Right-click it in the list, or the "..." menu (goes to Trash) |
| Pin a note | Right-click it in the list. Pinned notes sort to the top |
| Links | Click any URL in a note |
| Checkboxes | Click a `- [ ]` to tick it. Ticked lines dim |
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

## Inbox

The panel has two surfaces: **Notes** and **Inbox**. The inbox pools notifications
from iMessage, Slack, WhatsApp and Discord into one list, so opening the drawer
shows your notes and everything waiting for you in the same place. A dot appears
on the tab when something is unread.

Right-click a message to **Save as Note**, which is the reason both surfaces live
in one panel: something asked of you in Slack becomes a note in your notes folder,
with the source recorded. Clicking a message opens the app it came from.

**This needs Full Disk Access**, granted once in System Settings, Privacy and
Security. macOS keeps every notification in one protected file; that single file
is why one integration covers all four apps. It is read only, and nothing leaves
your Mac.

Two things worth knowing. That file is a live queue of undismissed notifications,
not an archive, so aside keeps its own copy as messages arrive: it only sees what
lands while it is running. And it can only read, so replying means opening the
source app. Mute an app from the right-click menu.

## Slack

Slack replies go through its official API with a **user token**, so they post
under your own name with no "APP" badge. Bot tokens are what produce that badge.

Create the app at [api.slack.com/apps](https://api.slack.com/apps) with **From a
manifest** and paste `slack-app-manifest.yaml`, then Install to Workspace. The
token it gives you starts `xoxp-` and is stored in your Keychain, not in a
preferences file.

## Displays

Drag the tab and it follows your pointer, re-pinning to the right edge of
whichever display the pointer is on. On this machine the ultrawide sits above
the built-in screen, so dragging the tab up moves it to the ultrawide. The
"..." menu has an explicit "Show On" picker for the same thing.

The choice is remembered by display id, then by display name if the id changed
across a reboot. Unplugging a display parks the tab on the primary screen
without forgetting the preference, so plugging back in restores it.

## Where notes live

`~/Documents/Aside/*.md` by default. Change it with **Notes Folder...** in the
"..." menu, or point it at an Obsidian vault so your notes live alongside the
rest of your writing.

Edits you make elsewhere show up here **live**, without reopening the drawer.
If you are mid-sentence when an outside edit lands, your typing wins: the app
never overwrites what you have not finished.

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
./test.sh                                  # the whole suite
./build/snapshot preview.png dark inbox    # render a surface offscreen to a PNG
```

`tools/` is development only and is not part of the app bundle.
