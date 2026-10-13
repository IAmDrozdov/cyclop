# How Cyclop works

*English · [Русский](architecture.ru.md)*

Notes on the decisions the code does not show: why the window is shaped
the way it is, why the pointer is polled on a timer, what sitting
idle costs. These lived in the README and took up more than half
of it — moved here whole, word for word.


**The window.** One `NSPanel` per display — borderless, non-activating, one
level above the menu bar, `canJoinAllSpaces`. It is always the same size (that of
the expanded panel) and never changes its frame: only the content animates. That
is what makes the animation smooth without the window geometry jerking about.

**Displays.** Every connected display gets a notch of its own, so the panel is
always the one at the top of the screen being looked at rather than the one on
some other machine's idea of the main display. The split follows the pointer: it
is on exactly one display at a time, so open, drop-targeted and holding-the-
keyboard belong to a screen (`PanelState`) while the tab, the stores and the
running services are shared by all of them (`NotchViewModel`) — one clipboard
history, one of everything that costs something.
Displays are reconciled by `CGDirectDisplayID` rather than by position in
`NSScreen.screens`, which hands out fresh instances and reorders them on every
reconfiguration; a display whose notch has not moved keeps its panel untouched.
Mirrored displays are skipped — a second panel drawn over the same picture.
Settings → Displays folds it all back to one screen.

**Click-through.** The window frame is 700 × 252 pt at the top centre of the
screen, and most of the time almost all of it is transparent. Returning `nil`
from `hitTest` does not help: the window server has already chosen our window as
the recipient, and `nil` merely discards the event instead of passing it down.
Transparency does not affect routing either. The one thing that works is
`ignoresMouseEvents`, toggled by pointer position: inside the visible panel the
window takes clicks, outside it is completely transparent to events.

**Hover.** The pointer position is sampled on a timer rather than delivered by
event monitors. Monitors are structurally unreliable here: a global one never
sees events delivered to the app's own windows, and a local one only fires while
the app is active — which never happens to an `.accessory` app. Hovering would
then depend on which window happened to be under the pointer. Reading
`NSEvent.mouseLocation` does not depend on event routing and behaves identically
everywhere.

**The cursor.** Its shape is chosen by the window server from cursor regions: the
topmost window that claimed a region under the pointer wins. Claiming nothing
does not mean "leave the cursor alone", it means dropping out of that lookup, and
then the window below decides — over a text editor the panel was handed an
I-beam. Ordinary cursor rects will not do, as AppKit disables them for non-key
windows. So `NotchRootView` keeps an `NSTrackingArea` with `.cursorUpdate` and
`.activeAlways` over exactly its clickable area.

**Hovering over tabs.** The pointer crosses the panel in transit, so "hover
switches" would switch tabs on every crossing of the rail. The difference between
"I want this one" and "just passing" is time: a passing pointer clears an icon in
tens of milliseconds, a choosing one stops. A 150 ms threshold separates the two
cases, and nothing else is needed for it. The icon grows under the pointer via
`scaleEffect` rather than a change of `frame`: a layout that recalculates on
mouse movement reads as a stutter.

A tab that types takes the keyboard immediately — on hover as well. A panel that
shows a field but accepts no keys is worse than a caret dimmed for a second in
someone else's window, and the dwell on the rail already keeps a passing pointer
from arriving here at all. The reverse is still possible: a click into another
app drops the keyboard without touching the tab — what was typed stays, and the
panel is free to collapse. The keyboard comes back with a click on the field,
caught in the window's `sendEvent`: a gesture on `TextEditor` never fires,
because the text view claims mouseDown before SwiftUI does.

**A screenshot from the iPhone.** The Action button on the phone runs a shortcut
of two steps: "Take Screenshot" and "Copy to Clipboard". Continuity carries the
copy to the Mac, and the screenshot lands on the shelf. Not one tap, no cloud, no
shared network: the link is direct, like AirDrop's, and encrypted the same way.

There is no shorter path, and the others were tried. Syncing through Photos would
wait on the cloud. AirDrop cannot be aimed from a shortcut — iOS offers it only
through the share sheet, which costs a choice of device every time. A receiver of
our own on a port worked, but required a shared Wi-Fi and spoke plain HTTP. The
clipboard requires nothing.

It cost one correction in how the clipboard is polled. A copy made on the phone
arrives in two parts: macOS puts the type on the pasteboard the moment the phone
announces the copy, while the picture is still coming over the air. The change
counter has already moved and been marked as seen by then — so a single read
returned nothing, and the screenshot vanished entirely, without an error and
without a trace. An announced but not yet delivered picture is now waited for:
the poll repeats for up to six seconds and stops as soon as the clipboard moves
on, because a copy made meanwhile is the newer intention, and finishing a
superseded transfer would put the wrong thing on the shelf. If the picture never
arrives, the text that lay beside it is recorded instead — otherwise a copy that
merely offered an image would disappear from the history altogether.

**Snippets.** Clipboard history is a queue ordered by recency, and the thing
needed once a week is washed out of it precisely because it is rare. Snippets are
the opposite discipline: a short, permanent list that nothing fills by itself. It
lives in a file:

```json
[
  { "label": "Email", "text": "name@example.com" },
  { "text": "+1 555 000 00 00" }
]
```

`~/Library/Application Support/Cyclop/snippets.json`, where `label` may be left
out. "Show Snippets File" in Settings opens it in Finder.

Both sides can add to it: the button in the panel and your hands in the file. A
snippet made in the panel is appended to that same file — but the file is re-read
first. The copy in memory is only as fresh as the last visit to the tab, and
writing over it blind would silently undo whatever was added in an editor
meanwhile. A name without a value means nothing, so only the second field is
required; a row without a name shows itself, which is usually enough for an
address or a phone number.

The file is plain text — ordinary JSON in the user's folder, unencrypted. For an
email and an address that is fine; for anything that should not be left readable,
there is a password manager.

Clicking a snippet overwrites the clipboard, deliberately: what was overwritten
stays in the Clipboard tab one click away, whereas restoring it on a timer would
be guessing when the paste happens, and typing into another app's field directly
would have required Accessibility.

**Hiding contents.** The "Hide Contents" menu bar item covers what the tabs
show with a field of twinkling dots — for a screen-shared call, a stream, or a
café. Enabled as a whole or per section — clipboard and snippets —
and off by default. A hidden row is not drawn at all: this is no blur, there is
nothing in the frame to recover, and the field covers the whole row rather than
tracing the glyphs — a silhouette would give away the length. The eye on a row
uncovers it for a while, folding the panel covers everything again, and copying
works over the cover — the hidden can be used without being shown. Proposed and
written by the community (#16, PR #17).

**Languages.** Russian and English; macOS picks by the user's preferred language
list. The keys in the tables are the English text, so a string without a
translation stays an English phrase instead of turning into an identifier — which
is also what keeps the app readable when run straight from SwiftPM, where the
`.lproj` folders are not around at all.

Everything the app composes itself follows the chosen language rather than the
system one: those two differ more often than one expects. The language
names in the Translate header and the number format of the Currency amounts come
from `Bundle.main.preferredLocalizations`, or a column headed in one language
above a button worded in another would read as a mistake.

An individual app's language can be changed in System Settings → General →
Language & Region → Applications.

**The keyboard.** The panel cannot become key by default: taking focus means
dimming the title of whatever window the user is in and stopping the caret
blinking in their text, which is far too rude for a window one merely hovered.
Every tab that types turns `canBecomeKey` on for as long as it is open, and so
does the Teleprompter while its script is empty; `.nonactivatingPanel` allows
keyboard input without activating the app, so the editor underneath stays
active. The keyboard goes back on a tab change, on a click into another app —
which the panel catches as the loss of key status — and simply when the panel
collapses. Esc does not give it back: in Translate, Currency and Snippets it
clears the field.

The panel does not try to stay open on account of text typed into it: there is
one rule for the whole app — open while the pointer is on it. What was typed
survives, so leaving and coming back is safe at any moment. Pinning was tried
here and removed: it added a second way to close the panel that had to be
remembered separately, and a panel that sometimes disobeys the pointer is worse
than one that always obeys it.

**Translation.** `Translation.framework`, entirely offline. Both languages are
named explicitly: Cyrillic goes out to the foreign language, everything else
comes in to Russian. The foreign language is English or Polish, switched by a
click on its column title and kept in `UserDefaults`: the two share a script,
so the text cannot say which one it is. The direction is decided by script
rather than by language identification — a single word is far too short to
identify reliably, and "привет" is regularly detected as Bulgarian. Leaving the source language to the
framework is not an option either: its identifier is a separate asset that is
equally not installed, so auto-detection fails with `unableToIdentifyLanguage`,
and the `translate` that follows never returns at all.

Language packs are not preinstalled in macOS. `prepareTranslation()` is what asks
the system for one, but it shows a window of its own and blocks until answered —
and there is nowhere to show it above the borderless panel of an app that is
never active. So the pair is checked through `LanguageAvailability` first, and if
the pack is missing the panel says so and offers a button into System Settings →
General → Language & Region → "Translation Languages…".

**Notch geometry.** The width is `screen.frame.width` minus
`auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the height comes from
`safeAreaInsets.top`. On the MacBook Air M4 it was developed on, that is
179 × 32 pt.

**The collapsed target.** A real notch is a hole: nothing is drawn over it, and
the panel can claim all of it, because there is nothing underneath to take a
click away from.

Claiming it is not the same as opening on a touch. The panel used to open a few
points before the pointer reached the hole, after 50 ms, and a pointer on its way
along the menu bar or to a window underneath opened it by brushing the edge. Now
the tip of the arrow has to be inside: 8 pt from either side and 11 pt from
below, about half the arrow each way, held for 120 ms, which a pointer crossing
the notch along the menu bar does not last. The rule is about the tip, not the
arrow's picture: the picture hangs right and down from the tip, so "half the
arrow overlaps" would open sooner from the left than from the right. The top edge
stays in the target, so throwing the pointer up into the notch still works. Both
numbers are the Depth and Dwell sliders in Settings (`notch` in `config.json`),
and moving one re-reads the target without rebuilding the panel, which would
close it under the slider.

A notch we draw is an 8-point strip along the very top edge, and the strip is
what answers the pointer. It used to be drawn the height of the menu bar, which
holds only while the bar is there: any window in full screen hides it, and on a
second display macOS paints it only while that display has focus. The shape was
then left standing on whatever lay underneath — browser tabs, as often as not
(#109). Whether the bar is showing right now is not something a geometry built
once can know, so the notch no longer depends on it: a strip is right with the
bar and without it.

The strip is reached by throwing the pointer up, while a pointer travelling to a
menu bar icon or a tab stays below it. For the same reason the delay before
opening is a fixed 200 ms here, and the sliders do not reach it. The old
full-height notch comes back with a switch in Settings.

**Callbacks from system frameworks.** A closure handed to a system framework
that runs it off the main thread is marked `@Sendable` explicitly, like the
shelf's QuickLook completion. Whether a closure written inside a `@MainActor`
type is isolated is decided by the SDK's declaration of the parameter, not by
Cyclop's code, and the answer differs between compilers. An inherited isolation
is checked at run time when the closure is called, and the framework calls it
from a queue of its own, so the check kills the process. A closure that passes
on one Mac then crashes on a release build: 0.8.0 fell over on shelf previews
this way (#108; #111 was the same crash elsewhere). Written out,
`@Sendable` makes the closure nonisolated under any compiler.

The screenshot folder watcher is the exception, and only by construction. Its
handlers inherit the isolation, because `setEventHandler`
does not mark its parameter `@Sendable`, and they are safe without the mark
only because the dispatch source is created on the main queue. Moving it to
another queue crashes at the first change in the folder.

**Staying awake.** The Caffeine tab does two different things. A caffeine
session takes a public IOKit assertion against idle system sleep, which dies with
the process; the display is deliberately not held. Lid-closed mode sets a bit
in the kernel through the power-management root domain's user client
(`kPMSetClamshellSleepState`, whose selector is in a public header; the call
itself is undocumented). It needs no root and no permission, but the bit
outlives the process, is shared with `powerd` and other apps (last writer
wins), cannot be read back, and clearing it while the lid is closed sleeps the
Mac at once. So the store sends it again after a screen change, a power-source
change, a wake, a lid change and every 30 seconds, clears it on quit, and on
every launch sends the value the switch calls for. No watchdog: after a crash
the bit stays until the next launch or a reboot. Only while the lid is closed
does the mode also hold the idle-sleep assertion, since the bit alone only
stops the lid from sleeping the Mac, not the idle timer. Everything goes through
a power port, the one seam the store's tests use.

**Meetings.** A recording is two tracks because the owner's voice and the other side's reach the Mac by different roads: the microphone, and everything the Mac plays, caught by a Core Audio process tap on a private aggregate device. Two tracks make «Me» and «Speaker» exact for free; separating voices is only needed on the system track. Both are written as uncompressed 16-bit PCM in CAF, because compressed AAC in a CAF is unreadable until its packet table is written at close, and a killed app would lose the whole meeting. The tracks are compressed to one stereo `audio.m4a` only after the transcript is on disk, and the originals go only after the result is checked. Processing runs after Stop, one meeting at a time: with both sides present, the microphone is cleaned against a mono mix of the system track (LocalVQE), each track is recognised with no language hint, the system track is split into voices on the same file the recogniser read so both share one clock, words get a voice when it covers half of them and leads the runner-up by a fifth, the lines are merged by time, and a line of the owner that only repeats the other side is dropped. `transcript.json` is written after the Markdown file and is the mark of a finished meeting, so a crash in between is simply processed again. Every step falls back toward keeping text: no library, a bad checksum or a failed separation leaves a transcript from the raw tracks. The signature has to be stable: macOS ties the microphone and system audio permissions to it, and an ad-hoc signature changes with every build, so the build signs with a self-signed «Cyclop Local» when it exists.

**The cost of sitting still.** At rest the app does nothing, and that is
measurable: with the pointer still and the panel collapsed it sits at 0.0 % CPU,
and a sampling profiler shows the whole process asleep in `mach_msg2_trap`. The
fractions of a percent appear only while the pointer travels near the top edge
or the panel is open — the price of interaction, not of idling.

That comes from a rule rather than a trick: a timer runs only while somebody can
see what it produces. Pointer sampling requires place and motion both: 60 Hz
only while the pointer has moved recently near the top edge or on the open
panel; one that has stood still for three seconds drops sampling to 8 Hz
wherever it stands. Place alone was not enough — a cursor parked in the menu
bar, which lies entirely inside the warm band, used to hold full rate forever.
Movement is noticed on the next idle tick, 125 ms at worst, less than the dwell
a hover has to survive anyway. A sleeping display stops sampling entirely.

Store updates do not repaint a collapsed panel at all: a panel nobody can see
is painting for nobody. Clipboard polling reads one change counter twice a second, and image data is not touched
while screenshot saving is off — it used to be encoded to PNG in full and thrown
away. Every timer carries a tolerance so the system can coalesce wake-ups. And
no leaks: `leaks` against the live process finds zero.
