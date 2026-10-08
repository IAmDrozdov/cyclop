# Calendar, Notes and Music are deleted, not hidden

The fork deletes the Calendar, Notes and Music tabs from the code instead of switching them off in Settings → Show in Panel, which is what upstream's rule for a rarely used tab asks for: keep it, and let it be switched off. The owner has no use for the three. Deleting them also takes out the Now Playing helper (an Objective-C dylib run inside `/usr/bin/perl` against a private framework, with its own build, signing and CI steps), the Calendar and Automation permissions with their usage strings and entitlements, the artwork request and about 2 200 lines of Swift. Hidden, all of that would still be built, signed and documented.

## Consequences

- The rails become four and four: left Shelf, Clipboard, Snippets, Translate; right Currency, Teleprompter, Utilities, Settings. The right rail stays because the left one holds the tabs glanced at most often and the rare modes and Settings go to the right (#43), not because the left one is full.
- Shelf, the first tab of the left rail, becomes the default tab.
- The notes on the Now Playing helper and the scripting fallback leave `docs/architecture.md` and `.ru.md`; they remain at 125eb02, where the fork left upstream: `git show 125eb02:docs/architecture.md`.
