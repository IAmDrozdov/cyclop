---
name: update-readme
description: Manual only, runs when the owner types /update-readme. Refreshes README.md, README.ru.md and the pictures under docs/images/readme/ from the code drift since the last stamp, re-shooting pictures from the demo build. Never invoke on your own.
disable-model-invocation: true
---

# Refresh the README and its pictures

`README.md` and `README.ru.md` are the public face of a public repo, and their pictures come from
the demo build's invented data, never from the owner's. Work only on what `drift.py` names. Manual
only: the owner calls this skill, nothing triggers it.

Files beside this one: `map.json` (the stamp and the path map), `drift.py`, `shoot.sh` (the
pictures). The demo build is `./Scripts/bundle.sh demo`; its data is seeded by
`Sources/Cyclop/App/Demo.swift` (docs/architecture.md, "The demo build").

## 1. Scope the drift

`python3 .claude/skills/update-readme/drift.py` lists the commits since the stamp, the README
sections and pictures whose paths changed (uncommitted work counts; a file edited again after a
stamp is listed again, a file reverted to its stamped content is not; pictures in `pending` are
always listed), and `UNMAPPED`: watched paths no entry claims. The report is also written to
`.local/readme/report.md`. Settle every UNMAPPED path in `map.json`: add it to an entry's `paths`,
to `ignore`, or give a new tab a section, a seed in `Demo.swift`, a scene in `shoot.sh` and a
`pictures` entry.

**Done when:** nothing is UNMAPPED and the stale sections and pictures are listed.

## 2. Update the text

For each stale section read its lines in both READMEs and `git diff <stamp> -- <its paths>`. Edit
surgically and copy names, labels, limits and paths from the code, never from memory: English UI
labels from `Resources/en.lproj/Localizable.strings`, Russian ones from `ru.lproj`. Both READMEs
change together and keep the same headings (`heading`, `heading_ru` in `map.json`) and pictures.
Link `docs/architecture.md` instead of repeating it.

**Done when:** each stale section matches its diff in both languages, or is noted "no text change"
with the reason.

## 3. Pictures

`.claude/skills/update-readme/shoot.sh [scene ...]` (no scene shoots all ten) builds the demo
bundle, starts it once per scene on a throwaway folder, crops the panel body out of its own window
and writes `.local/readme/shots/<scene>.png`. It quits the app and deletes the folder and the
`com.cyclop.app.demo` preferences on success, failure and Ctrl-C. A missing Screen Recording
permission stops it with the name of the app to grant it to: grant it, do not work around it.

`Read` every new PNG against this checklist before keeping it: only demo data (no real name, path
under the owner's home, clipboard text, session, meeting, token or signing identity), no other
window, wallpaper or menu bar, nothing cut off, same size as the other pictures of its kind. Copy the
kept ones to `docs/images/readme/`, and each picture named in `copies` in `map.json` to its other
path too (the site's `docs/panel.png` is `shelf.png`; a new size goes into its `<img>` and
`og:image` sizes in both `docs/index.html` and `docs/ru/index.html`).

**Done when:** every stale picture is re-shot and checked, or kept with a reason.

## 4. Validate

`python3 .claude/skills/update-readme/drift.py check`, then the gate in `CLAUDE.md`
(`./Scripts/bundle.sh`, `./Scripts/test.sh`, `./Scripts/check-strings.py`).

**Done when:** `OK` and the gate passes.

## 5. Stamp and report

Run `drift.py` once more, then `drift.py stamp [--pending FILE ...]` with the pictures still stale.
`stamp` refuses without a report made against the current stamp or with UNMAPPED paths in it, records the HEAD that report saw
and absorbs only the uncommitted files it listed, unchanged since; each report allows one stamp. No
`git add`, commit or push. Report: commits covered, sections changed or left, pictures re-shot,
kept or pending, and the files for the owner to commit. When the owner asks to commit: the work
first, then `map.json` alone, since the stamp cannot name a commit made after it.

**Done when:** the report is delivered.

## Never
- Run without the owner's call, or commit or push.
- Shoot the owner's running Cyclop, real state or real `~/.claude`: only the demo build.
- Keep a picture that has not been read against the checklist.
