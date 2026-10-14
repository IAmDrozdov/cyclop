# Cyclop

*English · [Русский](README.ru.md)*

The MacBook notch as a working tool. A native SwiftUI/AppKit app: invisible at
rest, and on hover it unfolds downwards into a panel with a shelf for files,
clipboard history and offline translation.

[![build](https://github.com/akalikbergenov/cyclop/actions/workflows/build.yml/badge.svg)](https://github.com/akalikbergenov/cyclop/actions/workflows/build.yml)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-%E2%98%95-FFDD00?style=flat-square&labelColor=000000)](https://buymeacoffee.com/akalikbergenov)

![The Cyclop panel](docs/panel.png)

**[Download the latest version](https://github.com/akalikbergenov/cyclop/releases/latest)** —
macOS 15 or newer. Signed and notarised, so it opens on the first try.

```
0.0 % CPU at rest  ·  ≈16 MB  ·  3.1 MB bundle  ·  nothing asked at launch
```

## What it does

| Tab | What it does |
|---|---|
| **Claude** | The Claude Code sessions on this Mac, the ones that wait first: working, waiting or idle, where each runs (the Claude app, an editor, a terminal) and for how long; the header counts the waiting ones, and a press on a row opens that session in Claude (in a terminal, its tab is selected, if macOS allows it). Press *Connect to Claude* once in Settings and a request (a permission, a question, a plan) shows up in the panel to be answered there: allow or deny, pick an option or type your own answer, approve a plan or send it back with remarks. A plan is approved the way you choose: keep the context with the same model and go on in the same session; whenever the context is compacted or cleared, or the model changes to Sonnet, Cyclop starts a new session where the plan was made (a terminal window or tab, the Claude app or the editor) and the old one stays in plan mode. Effort and permission mode are chosen on the card for a terminal session or an in-place approval, and the defaults (clear, Sonnet, medium, bypass permissions) are in Settings; a session handed off to the Claude app or the editor carries neither, so the card hides those two rows and the mode and effort are chosen in Claude when the session opens (type go there to start). The new session spends your Claude tokens like any other. Claude keeps asking in its own window too, and whichever answer comes first counts. When a request arrives the panel slides out on this tab by itself, with the buttons, and folds when the request is answered or gone; if you move the pointer into it and out again it folds as usual and the request waits in the tab. A switch in Settings turns this off. There is no sound and no notification. The connection is one entry in Claude's settings file, written only by that button and removed by its twin (see SECURITY.md). Hide Contents can cover session names and the text of requests |
| **Shelf** | Drag files into the notch and they stay there until needed; drag a card out and the file goes wherever it is dropped. A click selects a card, ⌘-click selects several, and then the whole group is dragged. A screenshot taken to the clipboard is saved as a file and lands here too — including one taken on an iPhone, if you copy it there |
| **Clipboard** | The last 40 copies; a click puts an entry back on the clipboard |
| **Snippets** | A hand-kept list of what you are tired of retyping: an address, a phone number, an email. Added with a button in the panel, removed with the cross on a card; a click puts the text on the clipboard. The same list lives in `~/Library/Application Support/Cyclop/snippets.json` and can be edited there instead |
| **Translate** | Type on the left, the translation appears on the right — by itself, offline, using macOS's own facilities. English or Polish goes to Russian, Russian goes back; a click on the language's column title switches between English and Polish, and the direction comes from the script the text is written in. macOS does not preinstall language packs, so the first time you have to download one: System Settings → General → Language & Region → "Translation Languages…" |
| **Caffeine** | Keeps the Mac from falling asleep: one button for no end, or a timer on an hour-and-minute wheel. Only the system stays awake — the screen still turns off and locks on its own schedule. The tab's icon is tinted while a session runs, and the header shows the time left. A session ends when you stop it, when the tab is switched off, or when Cyclop quits. A separate switch, Stay Awake with the Lid Closed, keeps the Mac awake with the lid shut, so that agents keep working while you are away |
| **Currency** | An amount on one side, the other currency on the other; type into either. Rates come over the network — a public table of daily rates, fetched once an hour, and only while the tab is on (the other download is the one-time speech models of Meetings) |
| **Meetings** | A *Start Recording* button records a call on two tracks: the microphone and everything the Mac plays. After *Stop* the meeting becomes a transcript on this Mac, nothing leaves it: your lines are *Me*, the other side is *Speaker*, with a letter (A, B, C) when several voices can be told apart, and the language is detected by itself, so Russian, Ukrainian and English may share a call. The journal keeps every meeting; *Export* puts a folder with the transcript and the audio into Downloads. The speech models (about 700 MB) are downloaded once, by a button, and the first Start asks macOS for the microphone and system audio |
| **Teleprompter** | A script that scrolls under the camera at a speed you set. The notch is the one place on the screen a teleprompter belongs: reading happens right beside the lens, so on the recording the eyes stay on the camera instead of travelling to a window below it. The panel holds itself open while the text is moving — reading a script means not touching the trackpad |

The panel opens when the pointer reaches the notch and collapses when it leaves.
Tabs switch on hover as well — but only if the pointer has come to rest on the
icon: one passing through switches nothing. During a file drag the panel opens by
itself and goes straight to the shelf. The menu bar icon toggles the panel,
hides every tab's contents at once, and quits. The icon itself can be
removed — ⌘-drag it off the bar, or flip the switch in Settings — and
relaunching Cyclop brings it back.

Any tab can be switched off in **Settings → Cyclop → Show in Panel**. Off means two
things: the icon leaves the rail, and the tab's background work stops with
it — the clipboard poll and the
rate fetch. The rail is for what gets a glance between other things; a mode
used once a month may live there, but only as long as the people who never
use it can take it off.

Hold an icon (or press it hard on a Force Touch trackpad) to lift it, then drag
it along its rail or onto the other one. The icon size is set in the same
Settings section; a long rail makes the panel taller instead of shrinking icons.

## Requirements

- macOS 15 or newer (the Translate tab runs on Translation.framework)
- Swift 6 toolchain (the full Xcode is not needed, Command Line Tools are enough)
- CMake (`brew install cmake`), for the echo canceller of the Meetings tab; `CYCLOP_SKIP_LOCALVQE=1` builds without it

The app works on Macs without a notch too: the panel then treats a 180 × 24 pt
area at the top centre of the screen as one.

## Building

```bash
git clone https://github.com/akalikbergenov/cyclop.git
cd cyclop
./Scripts/bundle.sh          # swift build + assemble the .app + ad-hoc sign
open build/Cyclop.app
```

The icon is generated in code, with no graphics editor involved:

```bash
swift Scripts/make-icon.swift "$PWD/Resources/AppIcon.icns"
```

## Installation

Open `Cyclop-<version>.dmg` and drag the app into Applications. It opens on
the first try: since 0.8.0 the image is signed with a Developer ID and
notarised by Apple, so there is nothing to allow and nothing to type.

Updating works the same way: open the new image and replace the app. The
version is the first line of the menu bar menu.

A build from source (`Scripts/bundle.sh`) is ad-hoc signed and is not
notarised, so on any Mac but the one that built it the first launch goes
through **System Settings → Privacy & Security → "Open Anyway"**. Releases do
not have this step.

Releases come often, and a star does not announce them — it is a bookmark, not a
subscription. To hear about updates: the **Watch** button at the top right →
**Custom** → tick **Releases**. Only releases will arrive, no issues or pushes.

### Building the image yourself

```bash
./Scripts/dmg.sh
```

Puts `build/Cyclop-<version>.dmg` next to the app, with an `/Applications`
shortcut inside. The version number comes from `Scripts/version`.

### Cutting a release

```bash
./Scripts/release.sh
```

Builds the image, tags `v<version>` and creates a GitHub release with the `.dmg`
attached. The notes are two parts: a few lines written by hand, kept in
`docs/releases/<version>.md`, followed by the commit list GitHub assembles. The
script refuses to run without the hand-written part — a list of commits answers
"what changed in the code", while whoever arrives is asking "what does this give
me", and no generator turns the first answer into the second.

The number is written in **one place**, `Scripts/version`. From there it goes
into the app's `Info.plist`, into the image name and into the tag, so they cannot
drift apart. The script also refuses to run on a dirty tree, on unpushed commits,
or when the tag already exists.

Built images live on the [releases page](https://github.com/akalikbergenov/cyclop/releases) —
that is the link to hand to people instead of a file.

## Permissions

**Nothing at launch, and nothing until you press the button that needs it.**
That is the promise. Start Recording in the Meetings tab asks for the microphone and for
system audio recording, on the first press. The other press that can ask is Open
in Claude on a session that runs in Terminal or iTerm: macOS asks once whether
Cyclop may control that terminal, so that the session's own tab is selected;
only the tabs' device names are compared, no text is read, and if you refuse, the terminal is only
brought forward. The pointer position is read through
`NSEvent.mouseLocation`, the clipboard through the public `NSPasteboard`.

The Claude tab asks macOS for nothing but that terminal permission, which a plan handed off to a new session in Terminal or iTerm also uses, to open a window or tab and type a `claude` command there. Its one button, Connect to Claude, adds an
entry to Claude Code's settings file and listens on a local socket that only you
can reach; both happen only after the press, and SECURITY.md says what they touch
and what is left behind.

A file put on the shelf from Downloads, Documents or the Desktop is the one thing
macOS asks about separately, and it asks when the shelf is opened, not at launch.
Refusing breaks nothing: the card stays, just without a preview.

## How it works

Why the window is shaped the way it is, why the pointer is polled on a
timer, what sitting idle costs — nineteen notes on decisions the code does not show:
**[docs/architecture.md](docs/architecture.md)**.

## Limitations

- The shelf references files rather than copying them: move the original and the
  card disappears on the next launch. The exception is clipboard screenshots,
  which are saved into `~/Pictures/Cyclop` and are never deleted automatically,
  even when the card leaves the shelf. Only the user clears that folder: the
  “Clear Screenshots Folder” in Settings sends its contents to the Trash —
  a hand too, not a schedule.
- Entries typed `org.nspasteboard.ConcealedType` (password managers) never enter
  the clipboard history.
- A screenshot from the iPhone arrives through Universal Clipboard, so it needs
  what that needs: one Apple ID, Bluetooth and Wi-Fi on, Handoff enabled and the
  devices near each other. And it overwrites the clipboard on the Mac — what was
  overwritten stays in the Clipboard tab one click away.
- macOS does not preinstall translation languages — the first time, the pack has
  to be downloaded through System Settings; the panel says so and opens the right
  screen.

## Layout

```
Sources/Cyclop
├── main.swift                 entry point, .accessory
├── App/
│   ├── AppDelegate.swift      menu bar icon, launch at login
│   └── Strings.swift          string lookup, current language
├── Notch/
│   ├── NotchGeometry.swift    notch size and every rect derived from it
│   ├── NotchPanel.swift       the NSPanel above the menu bar
│   ├── NotchRootView.swift    panel hit-testing + drag & drop destination
│   ├── PointerWatcher.swift   pointer sampling: hover and click-through
│   ├── PanelState.swift       one display's share: open, dragged onto, typing
│   ├── NotchScreenPanel.swift the panel as it stands on one display
│   └── NotchController.swift  one model, one panel per display
├── Model/
│   ├── NotchViewModel.swift
│   └── PrivacyMode.swift      hiding contents: sections and reveals
├── Services/
│   ├── Claude/                sessions from Claude Code's files, requests over a local socket, the entry in Claude's settings
│   ├── ShelfStore.swift
│   ├── ClipboardStore.swift
│   ├── ScreenshotVault.swift  clipboard screenshots onto disk
│   ├── SnippetStore.swift     snippets: reading and writing snippets.json
│   ├── ConfigStore.swift      settings: reading and writing config.json
│   ├── Support.swift          ~/Library/Application Support/Cyclop
│   ├── DebouncedWrite.swift   writes to disk no more often than needed
│   ├── Translator.swift       Translation.framework, direction by script
│   ├── CurrencyStore.swift    rates over the network (the models of Meetings are the other download)
│   ├── CaffeineStore.swift    caffeine sessions and the sleep hold
│   ├── Meetings/              recording, speech recognition, transcript assembly, export
│   ├── TeleprompterStore.swift the script and where reading it has got to
│   └── ScreenshotFolderWatcher.swift  screenshots saved to disk, onto the shelf
└── UI/                        NotchShape, tab panes, theme
```

## Contributing

The rules are short and live in [CONTRIBUTING.md](CONTRIBUTING.md): what gets
taken, what does not, and what to check before sending. The main one is that
the app keeps to the permissions and connections that SECURITY.md lists, and a
change that adds one is a separate conversation.

What the app reads, what it keeps and where, where it goes on the network —
[SECURITY.md](SECURITY.md). The channel for vulnerabilities is there too:
private, no issue needed.

## Thanks

The app is free — no subscriptions, no ads, no data collection — and will stay
that way. If it turned out useful and you feel like supporting it:

**[☕ Buy Me a Coffee](https://buymeacoffee.com/akalikbergenov)**

Special thanks to everyone who showed up in the first days and made the app
better: [@DontTrustMexD](https://github.com/DontTrustMexD),
[@a58becde](https://github.com/a58becde),
[@ispy4you](https://github.com/ispy4you),
[@iFuzYs](https://github.com/iFuzYs),
[@zhd-dm](https://github.com/zhd-dm),
[@komekovars](https://github.com/komekovars),
[@superkai-sdk1](https://github.com/superkai-sdk1),
[@Ariet2003](https://github.com/Ariet2003).

## Licence

MIT
