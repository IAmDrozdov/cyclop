# Cyclop

A macOS app that turns the notch into a hover panel of tabs. Swift 6 (SwiftUI + AppKit) on SwiftPM alone: there is no Xcode project, and a script assembles the `.app`. macOS 15+. A personal fork of akalikbergenov/cyclop.

Domain words (tab, rail, pane, panel, drawn notch, Hide Contents) are defined in `CONTEXT.md`, with each tab's Russian UI name. Two go by other names in code: Music («Музыка») is `media`, and Hide Contents («Скрывать содержимое») is `PrivacyMode`.

## Commands

Run from the repo root.

- `./Scripts/bundle.sh`: builds `build/Cyclop.app` (about 30 s) and is the compile check. Plain `swift build` fails with Command Line Tools on the macOS 27 SDK, where `@State` is a macro; the script switches to an older SDK through `Scripts/sdk.sh`.
- `./Scripts/test.sh`: unit tests (`swift test` plus the Command Line Tools paths for `Testing`).
- `./Scripts/check-strings.py`: every on-screen string has a key in both `Resources/*.lproj/Localizable.strings`. CI runs the same check first.
- `./Scripts/test-helper.sh`: checks the Now Playing helper in the last bundle.
- To run the app and see it working, use the `run-cyclop` skill.

## Done

A change is done when `bundle.sh`, `test.sh` and `check-strings.py` pass, plus `test-helper.sh` when Music code changed. Unit tests are for stores (`Services/*Store.swift`) only, and today only `SnippetStore` has them. The panel (notch, hover, rails, animation) is checked by eye by design, as the comment in `Package.swift` explains, so finish a UI change by telling the owner what to look at in the running app.

## Rules

- A new macOS permission or a new network request is the owner's call: ask first. `SECURITY.md` lists the current ones.
- A tab's background work (poll, observer, timer, helper) starts in `NotchViewModel.startBackground(of:)` and stops in `stopBackground(of:)`, so a tab switched off in Settings costs nothing.
- UI strings are keyed by their English text in both `Localizable.strings` tables; `ru.lproj` holds the translation.
- A comment is written in the language of the comments around it: English in most Swift files, Russian in `Scripts/`, `.github/`, `Package.swift` and the tests.
- Commit subjects are Russian and state the result: «Нарисованная чёлка открывается через 200 мс, а не через 300».
- The fork no longer merges upstream: a wanted upstream fix is cherry-picked by hand (`docs/adr/0001-fork-diverges-from-upstream.md`).
- Bilingual docs change together: `README.md` with `README.ru.md`, `docs/architecture.md` with `docs/architecture.ru.md`. `docs/releases/*.md` are history and stay as they are.

## Where to look

- Why the window, hover, keyboard and Now Playing work the way they do: `docs/architecture.md`. Read the matching note before changing `Sources/Cyclop/Notch/` or the helper.
- Adding, removing or renaming a tab: `docs/agents/tabs.md`.
- Permissions, outgoing connections and what users are told about their data: `SECURITY.md`. Its file list is partial: the app's own files are the `Support.file(` and `Support.directory(` calls plus `ScreenshotVault`, and per-Mac state is in `UserDefaults`.

## Agent skills

### Issue tracker

Issues and specs live as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix), recorded as a `Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the repo root; ADRs go in `docs/adr/`, created with the first one. See `docs/agents/domain.md`.
