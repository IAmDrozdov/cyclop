# Tabs: where one is wired

A tab is a case of `NotchViewModel.Tab`, a pane view in `Sources/Cyclop/UI/<Name>Pane.swift` and usually a store in `Sources/Cyclop/Services/`. All displays share one `NotchViewModel`, so a tab is wired once. Use this when adding, removing or renaming a tab.

## Where a tab is wired

In `Sources/Cyclop/Model/NotchViewModel.swift`:

- `Tab`: `symbol` (an SF Symbol), `title`, `needsKeyboard` (typing tab), `wantsTallBody`, `canHide`.
- `Tab.defaultRails`: the order before the owner rearranges it. A new tab goes on one of its rails; `RailOrder.normalized` then appends it to that rail for owners whose `config.json` already has a saved order (`rails`).
- The store property and its line in `init`.
- `startBackground(of:)` and `stopBackground(of:)`, which list every tab, no-op ones included.
- `setPanelActive(_:)`, for what follows the panel opening: the flag the header's forwarding reads, and the shelf's first refresh from disk.
- The `tab` property's `didSet`, for arriving at and leaving a tab.
- `stop()`, for flushing on quit.
- The default `tab = .claude`, the head of the left rail.
- The `objectWillChange` forwarding list, which repaints header badges and deliberately leaves out stores that change on every keystroke.
- Only if the tab can ask for the panel (today Claude): `unseenRequestChanged()`, which switches the tab while every panel is collapsed, and its calls in `setPanelActive(_:)` and the `tab` property's `didSet`. A request also slides the panel out by itself (`requestArrived()`, `RequestOpening`, `NotchScreenPanel.openForRequest()`), unless Settings says no; see the Claude note in `docs/architecture.md`.

Elsewhere:

- `NotchContentView` in `Sources/Cyclop/UI/NotchContentView.swift`: `trailing` (the header badge) and `pane`.
- `SettingsPane` in `Sources/Cyclop/UI/SettingsPane.swift`: a tab's own settings go on the Tabs page (`NotchViewModel.SettingsPage`), as a section with the tab's name; the Cyclop page is for the app's. A tab that needs to send the owner there sets `settingsPage = .tabs` first, as Claude's `showSettings` does.
- `PrivacyMode.Section` in `Sources/Cyclop/Model/PrivacyMode.swift`, for a tab whose contents Hide Contents covers. The menu bar submenu builds itself from it.

## What the compiler catches

- **Removing**: delete the case and the store, and `./Scripts/bundle.sh` fails at every reference above except `PrivacyMode.Section`, which is its own enum. Delete that case by hand, or the Hide Contents menu keeps an item that covers nothing.
- **Adding**: only the exhaustive switches fail: `symbol`, `title`, `startBackground(of:)`, `stopBackground(of:)`, `trailing` and `pane`. Everything else in the list compiles without the new tab, so go through it by hand, rails first.

## What the compiler never sees

- **Strings.** In both `Resources/*.lproj/Localizable.strings` a tab's title sits under `/* Tabs */` (`/* Вкладки */` in ru) and most tabs' keys in a block of their own: Currency's `/* Currency */` and `/* Валюта */`. `./Scripts/check-strings.py` catches a missing key but not an orphaned one, so a removed tab's keys are deleted by hand.
- **Views outside the pane file** that only this tab uses: header badges at the bottom of `NotchContentView.swift`. An unused type still compiles.
- **Saved settings.** `config.json` stores `hiddenTabs` and `privacy` by raw value, and loading drops values it does not know. After a removal that is harmless. A rename keeps the old raw value (`case history = "clipboard"`), or a hidden tab comes back and a covered section is shown uncovered. `ConfigStore.migrated()` also spells out the section names. The `privacy` list names sections and has no marker for "all", so a section added later (Claude was the third) starts uncovered even for an owner who covered everything: tell them to tick it once.
- **The tab's own data.** A removed tab's file in `~/Library/Application Support/Cyclop/` (such as `notes.json`) stays on disk unread. The code leaves it alone; tell the owner it is there and let them decide what to do with it.
- **Permissions.** Info.plist usage strings live in `Scripts/bundle.sh`; entitlements live in `Resources/Cyclop.entitlements`, which `bundle.sh` passes (`--entitlements`) when it signs with a Developer ID (`docs/signing.md`).
- **Rail geometry.** Icons keep the size set in Settings; a longer rail makes the body taller (`NotchGeometry.standardBodyHeight`), and `maxBodyHeight` cuts the window for every tab on one rail, so a new tab grows that worst case by itself.
- **Comments** that name the tab.
- **Docs.**
  - `README.md` and `README.ru.md`: the tab's section in «A tour of the panel» / «Обзор панели», with its picture. The picture comes from the demo build, so the tab also gets a seed in `Sources/Cyclop/App/Demo.swift`, a scene in `.claude/skills/update-readme/shoot.sh` and entries in its `map.json` (a removed tab takes them with it); `/update-readme` walks through it.
  - `docs/architecture.md` and `.ru.md`: the tab's note.
  - `SECURITY.md` (data, permissions, network), the promises in `CONTRIBUTING.md`, and `CONTEXT.md`.
  - The site: `docs/index.html`, `docs/ru/index.html`, `docs/llms.txt`.
  - The agent docs: `CLAUDE.md` (its line naming what has tests: a tab with a store gets `Tests/CyclopTests/<Name>StoreTests.swift` and a mention there), this file and `.claude/skills/run-cyclop/`.
  - The ADR of the tab, if there is one: `docs/adr/0004-claude-requests-are-answered-through-a-hook.md` for Claude.

## Rules

- Background work runs only while the tab is visible: start it in `startBackground(of:)`, stop it in `stopBackground(of:)`.
- Every tab except Settings can be switched off (`canHide`); a rarely used one has to be.
- The left rail holds the tabs glanced at most often; rarer modes go to the right rail, Settings last.

## Precedents

- `git show 4576f89` adds the Currency tab: both string tables, `NotchViewModel`, a store, a pane, `NotchContentView`.
- `git show 8dba550` removes a feature end to end (the AirDrop inbox): the code, `Scripts/bundle.sh`, `README.md`, `SECURITY.md`.

## Done

- `./Scripts/bundle.sh`, `./Scripts/test.sh` and `./Scripts/check-strings.py` pass.
- A search for every name of the tab finds only the hits you meant to keep. Join the case, the English and Russian titles, the type names and the words the prose uses for its parts: for Translate, `/usr/bin/grep -rniIE 'translat|перевод' Sources Tests Resources Scripts .github docs .claude Package.swift *.md`. Hits in `docs/releases/` are history and stay. Words like "notes" also match release notes.
- In the running app (the `run-cyclop` skill) the rails show the intended icons in the intended order (with a saved order, the new tab at the end of its rail).
