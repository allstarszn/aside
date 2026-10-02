# aside.

A pull tab on the right edge of your Mac screen. Click it and a panel slides out over
whatever you are in, with your iMessage, Slack, WhatsApp and Discord notifications in
one list, your notes next to them, and Ask, an assistant that can search both. Click
the tab again and it is gone.

Free, MIT licensed, a few thousand lines of Swift. No account, no subscription.
The macOS app bundle is "Aside".

## Install

```
curl -fsSL https://aside-landing-two.vercel.app/install.sh | bash
```

The script checks for Apple's command line tools (it offers to install them and asks
you to run the line again), clones this repo to `~/.aside-src`, builds the app on your
Mac, installs it to `~/Applications/Aside.app`, and sets it to start at login and
restart after a crash. Nothing needs sudo and nothing is installed outside your home
folder. Run the same line again to update.

Requirements: macOS 14 or later. Ask needs macOS 26 (it uses Apple's on-device model).

## What it does

The panel has four surfaces: **Ask**, **Unread**, **Notes** and **Inbox**. A dot
appears on the tab when something is unread.

Reading notifications needs Full Disk Access, granted once in System Settings under
Privacy and Security. macOS keeps notifications in one protected file, and aside reads
it (read only). That file is a live queue, not an archive, so aside keeps its own copy
and only sees what arrives while it is running.

Right-click a message to save it as a note, with its source recorded.

## Connections

Open the Connections screen to see what is connected and what needs a permission.

- **iMessage**: read through the notification file, no token. Replying asks for
  Automation access the first time. Say yes.
- **WhatsApp**: notifications are read the same way. Replying from the panel needs
  **Advanced connections**, which is off until you turn it on. WhatsApp does not offer a
  way to connect a personal account, so Advanced connections talk to it the way its own
  web app does. **That is against WhatsApp's rules, and the company could restrict the
  account you connect.** Everything stays on your Mac.
- **Discord**: you get the notification, and clicking it opens the exact message in
  Discord. You cannot reply from aside, because Discord blocks sign-in from inside
  other apps.
- **Slack**: connected with Slack's own API, so replies post as you, with no "APP"
  badge. Slack limits apps like aside, so Slack unread refreshes slowly. The other three
  do not have that limit. The token is stored in your Keychain.

WhatsApp, Discord and Slack must have macOS notifications turned on, or the inbox stays
empty.

## Ask

Ask answers questions about your inbox and your notes, for example "What did we say
about the invoice?" It runs on Apple's on-device model by default, so with no key
nothing is sent anywhere.

**Smart answers** is optional. Paste your own Anthropic API key in the Connections
screen and Ask uses a Claude model for the thinking. The model never sees your inbox:
it asks for a lookup, your Mac runs it, and only short snippets (160 characters each)
go back to Anthropic. A question is capped at three lookups, and costs about 1 cent.
The key is stored in your Keychain. Without a key, Ask stays on your Mac.

## Looks

System, Glass or Black, from the "Look" item in the panel's "..." menu. Glass is the
default and is Apple's Liquid Glass, so it needs macOS 26 and shows as System without it.

## Notes

Notes live only inside aside, as plain markdown files in
`~/Library/Application Support/aside/notes`. There is no folder to pick and nothing is
written anywhere else. The first line of a note is its title and becomes its filename.
If you used an earlier version, the first launch copies your notes from `~/Documents/Aside`
and leaves the originals untouched. Deleting a note moves it to the Trash.

## Using it

- Open: click the tab. Close: click it again or press Escape.
- Move the tab: drag it, including onto another display. Or use "Show On" in the "..." menu.
  The choice is remembered by display id, then by display name.
- Pin a note or move it to the Trash: right-click it in the list.
- Quit: "Quit Aside" in the "..." menu. Quitting stays quit until you log in again.

## Privacy

- Your messages and notes stay on your Mac. aside has no server.
- Ask sends nothing unless you add your own Anthropic key. Then it sends the snippets
  described above, to Anthropic.
- Replies go to the person you are replying to, through the app you reply in.
- The install script sends one anonymous ping (a random id and nothing else) so installs
  can be counted. It gives up after 3 seconds and never blocks the install. Skip it with
  `ASIDE_NO_PING=1`:
  `curl -fsSL https://aside-landing-two.vercel.app/install.sh | ASIDE_NO_PING=1 bash`
- The website counts visits, scroll depth, sections reached and clicks on the install
  buttons and the copy button, using a random id kept in your browser. It is off if your
  browser sends Do Not Track.
- Usage sharing is off until you turn it on in Settings. If you do, aside sends once a day: a
  random anonymous ID, the aside version and your macOS version. Never your messages,
  contacts, names or any content. Turning it off stops the pings and deletes the ID.
  "See What's Sent..." in the "..." menu shows the exact text. This is the only thing the
  app ever sends about itself.

## Develop

```
./test.sh                  # the whole suite
./build.sh                 # build to build/Aside.app, nothing installed
./install.sh               # run the suite, then build and install the real copy
ASIDE_SKIP_TESTS=1 ./install.sh   # install without running the suite
./build/snapshot preview.png dark inbox   # render a surface offscreen to a PNG
```

`install.sh` runs the tests first so a broken build never replaces the working app. The
curl one-liner skips them. Command line tools only: no Xcode, no Homebrew, no
dependencies. `tools/` is development only and is not part of the app bundle.

Brand files are in `brand/`. Rebuild the icon after editing `icon.svg` with
`brand/build-icon.sh`.

## Uninstall

```
~/.aside-src/uninstall.sh      # installed with the curl line
./uninstall.sh                 # from a clone
```

This removes the app, the launch agent and its preferences. Your notes are left where
they are.

## License

MIT. See `LICENSE`.
