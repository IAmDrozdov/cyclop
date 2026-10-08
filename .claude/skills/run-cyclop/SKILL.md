---
name: run-cyclop
description: Build, relaunch and check the Cyclop app to see a change working. Use for /run and /verify, and whenever a change to the panel or a tab should be checked in the running app.
---

# Run Cyclop

The app is the bundle `build/Cyclop.app`. `swift run` starts a bare binary without translations or the Info.plist, so it is not the app.

1. **Build**: `./Scripts/bundle.sh` (about 30 s, ad-hoc signed). Done when it prints `==> done: …/build/Cyclop.app`.
2. **Relaunch**: `.claude/skills/run-cyclop/scripts/relaunch.sh`. It quits the copy started from `build/`, opens the new bundle, waits 10 s (`WAIT=` to change) and checks that the app is still running. Done when it prints `Cyclop is running`. On a crash it prints the log since launch and the newest crash report. Exit 2 means another Cyclop is running (the script prints its path): ask the owner whether to quit it, since two copies both draw a panel.
3. **Logs**: `log stream --style compact --predicate 'process == "Cyclop"'` while reproducing, or `log show --last 5m` with the same predicate. The app logs through `NSLog` only when something fails, so silence is normal.
4. **Look**: the panel opens only under the pointer, and you cannot see it. Ask the owner to hover the notch and name exactly what to check: which tab, which rail, what should appear or be gone.
5. **Stop**: `.claude/skills/run-cyclop/scripts/relaunch.sh stop` when the owner is done with it.

CI's launch step in `.github/workflows/build.yml` checks only that the app launches and stays up for 15 s on a fresh runner. It seeds the shelf with a file but never opens the panel, so it does not reach QuickLook, where 0.8.0 crashed (#108). For a change near the shelf or its thumbnails, ask the owner to drop a file on the shelf while the app runs and to hover the panel open.

The run uses the owner's real state: `config.json` and the store files in `~/Library/Application Support/Cyclop/`, and per-Mac state such as the shelf in the `com.cyclop.app` defaults domain. Upstream Cyclop has the same bundle id, so an installed upstream copy shares both. Permission grants follow the signature, and the build copy is ad-hoc signed, so it may be asked again for a permission the installed copy already has.
