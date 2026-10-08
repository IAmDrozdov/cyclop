# Tabs: where one is wired

A tab is a case of `NotchViewModel.Tab`, a pane view in `Sources/Cyclop/UI/<Name>Pane.swift` and usually a store in `Sources/Cyclop/Services/`. All displays share one `NotchViewModel`, so a tab is wired once. Use this when adding, removing or renaming a tab.

## Where a tab is wired

In `Sources/Cyclop/Model/NotchViewModel.swift`:

- `Tab`: `symbol` (an SF Symbol), `title`, `needsKeyboard` (typing tab), `wantsTallBody`, `canHide`.
- `Tab.leftRail` / `Tab.rightRail`: the order on screen. A tab in neither rail never appears, not even in Settings → Show in Panel.
- The store property and its line in `init`.
- `startBackground(of:)` and `stopBackground(of:)`, which list every tab, no-op ones included.
- `setPanelActive(_:)`, for a clock that ticks only while the panel is open.
- The `tab` property's `didSet`, for arriving at and leaving a tab.
- `stop()`, for flushing on quit.
- The default `tab = .media`.
- The `objectWillChange` forwarding list, which repaints header badges and deliberately leaves out stores that change on every keystroke.

Elsewhere:

- `NotchContentView` in `Sources/Cyclop/UI/NotchContentView.swift`: `trailing` (the header badge) and `pane`.
- `PrivacyMode.Section` in `Sources/Cyclop/Model/PrivacyMode.swift`, for a tab whose contents Hide Contents covers. The menu bar submenu builds itself from it.

## What the compiler catches

- **Removing**: delete the case and the store, and `./Scripts/bundle.sh` fails at every reference above except `PrivacyMode.Section`, which is its own enum. Delete that case by hand, or the Hide Contents menu keeps an item that covers nothing.
- **Adding**: only the exhaustive switches fail: `symbol`, `title`, `startBackground(of:)`, `stopBackground(of:)`, `trailing` and `pane`. Everything else in the list compiles without the new tab, so go through it by hand, rails first.

## What the compiler never sees

- **Strings.** In both `Resources/*.lproj/Localizable.strings` a tab's title sits under `/* Tabs */` (`/* Вкладки */` in ru) and most tabs' keys in a block of their own: Calendar's `/* Calendar */` and `/* Календарь */`, Music's `/* Media */` and `/* Музыка */`; Calendar has a second block for its countdown. `./Scripts/check-strings.py` catches a missing key but not an orphaned one, so a removed tab's keys are deleted by hand.
- **Views outside the pane file** that only this tab uses: header badges at the bottom of `NotchContentView.swift`, and `UI/Skeleton.swift`, which only Music uses. An unused type still compiles.
- **Saved settings.** `config.json` stores `hiddenTabs` and `privacy` by raw value, and loading drops values it does not know. After a removal that is harmless. A rename keeps the old raw value (`case history = "clipboard"`), or a hidden tab comes back and a covered section is shown uncovered. `ConfigStore.migrated()` also spells out the section names.
- **The tab's own data.** A removed tab's file in `~/Library/Application Support/Cyclop/` (such as `notes.json`) stays on disk unread. The code leaves it alone; tell the owner it is there and let them decide what to do with it.
- **Permissions.** Info.plist usage strings live in `Scripts/bundle.sh`, entitlements in `Resources/Cyclop.entitlements`.
- **Rail geometry.** `NotchGeometry.railIconHeight` sizes every icon by the static `Tab.leftRail.count`. Keep the left rail at least as long as the right one, or the right rail overflows.
- **Comments** that name the tab.
- **Docs.**
  - `README.md` and `README.ru.md`: the tab table and the layout tree.
  - `docs/architecture.md` and `.ru.md`: the tab's note. Both READMEs count the notes («eighteen notes»); update the count.
  - `SECURITY.md` (data, permissions, network), the promises in `CONTRIBUTING.md`, and `CONTEXT.md`.
  - The site: `docs/index.html`, `docs/ru/index.html`, `docs/llms.txt`.
  - The agent docs: `CLAUDE.md`, this file and `.claude/skills/run-cyclop/`.

## Rules

- Background work runs only while the tab is visible: start it in `startBackground(of:)`, stop it in `stopBackground(of:)`.
- Every tab except Settings can be switched off (`canHide`); a rarely used one has to be.
- The left rail holds the tabs glanced at most often; rarer modes go to the right rail, Settings last.

## Precedents

- `git show 4576f89` adds the Currency tab: both string tables, `NotchViewModel`, a store, a pane, `NotchContentView`.
- `git show 8dba550` removes a feature end to end (the AirDrop inbox): the code, `Scripts/bundle.sh`, `README.md`, `SECURITY.md`.

## Done

- `./Scripts/bundle.sh`, `./Scripts/test.sh` and `./Scripts/check-strings.py` pass.
- A search for every name of the tab finds only the hits you meant to keep. Join the case, the English and Russian titles, the type names and the words the prose uses for its parts: for Music, `/usr/bin/grep -rniIE 'media|music|музык|now ?playing|PlayerBridge|helper|хелпер' Sources Tests Resources Scripts .github docs .claude Package.swift *.md`. Hits in `docs/releases/` are history and stay. Words like "notes" also match release notes and calendar event notes.
- In the running app (the `run-cyclop` skill) the rails show the intended icons in the intended order.
