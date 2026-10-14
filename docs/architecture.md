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
Settings → Cyclop → Displays folds it all back to one screen.

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

**Rearranging the rails.** Holding an icon for 400 ms, or pressing it hard on a
Force Touch trackpad (a `.pressure` event at stage 2), lifts it, and dragging moves
it along its rail or onto the other one; the trackpad answers the lift with a
tap. The press is a SwiftUI `DragGesture` on the rail, not on the icon — an icon
that crosses to the other rail is a new view, and its gesture would end there —
and not an `NSDraggingSession`, which would open the shelf as a drop target. The
slot is counted from the rail's centre, which stays put while the rail gains the
icon. The order, hidden tabs in their places, goes to `config.json` (`rails`) on
every step, so a panel closing mid-drag loses nothing; a tab the file does not
name joins its default rail at the end. Icons keep the size set in Settings
(20–32 pt): a rail that does not fit the standard 208 pt makes the body taller,
and the window is cut once for the worst case, every tab on one rail at 32 pt.

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
café. Enabled as a whole or per section — clipboard, snippets and Claude —
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
clears the field. Claude is the exception that asks only on a press (see the
Claude note).

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

**Meetings.** A recording is two tracks because the owner's voice and the other side's reach the Mac by different roads: the microphone, and everything the Mac plays, caught by a Core Audio process tap on a private aggregate device. Two tracks make «Me» and «Speaker» exact for free; separating voices is only needed on the system track. Both are written as uncompressed 16-bit PCM in CAF, because compressed AAC in a CAF is unreadable until its packet table is written at close, and a killed app would lose the whole meeting. The tracks are compressed to one stereo `audio.m4a` only after the transcript is on disk, and the originals go only after the result is checked. Processing runs after Stop, one meeting at a time: with both sides present, the microphone is cleaned against a mono mix of the system track (LocalVQE), each track is recognised with no language hint, the system track is split into voices (Sortformer) on the same file the recogniser read so both share one clock, words get a voice when it covers half of them and leads the runner-up by a fifth, the lines are merged by time, and a line of the owner that only repeats the other side is dropped. `transcript.json` is written after the Markdown file and is the mark of a finished meeting, so a crash in between is simply processed again. Every step falls back toward keeping text: no library, a bad checksum or a failed separation leaves a transcript from the raw tracks. The signature has to be stable: macOS ties the microphone and system audio permissions to it, and an ad-hoc signature changes with every build, so the build signs with a self-signed «Cyclop Local» when it exists. Sortformer replaced FluidAudio's offline clustering after a test on call-quality audio (opus 24 kbit/s) of two to six real voices: the clustering found two voices in every scene and its mean error was 52 %, Sortformer's 26 %. It sees four voices at most, so a call with more merges the extra ones.

**Claude.** Claude Code leaves one small file per running process in
`~/.claude/sessions/`: the process id and its start time, the name, the folder,
the entrypoint (which says whether the session runs in the Claude app, an editor
or a terminal) and the state. The tab reads those files and nothing else, except
that a plan request makes it read the model name from a transcript's tail (see the
hand-off below). The format is internal, so the decoder is tolerant: every field is
optional, a file that does not parse or has no state is skipped, an unknown state
reads as waiting, and a session is alive when its id and start time match a
process, because the age of the file says nothing. The folder is watched for
entries added and removed, a slow timer covers a file rewritten in place and a
process that died without removing its file, and a reading is also taken when the
panel opens and when a request arrives.

States can be read; an answer has to get into the Claude Code process, and the one
supported door is a hook. Cyclop keeps one `PermissionRequest` entry in Claude's
user settings, written only by the Connect button. Its command is Cyclop's own
executable with `--claude-relay`, which never becomes an app: it passes the request
to a Unix socket in Cyclop's support folder (owner-only, the peer's user id is
checked, one connection carries one request), keeps the connection open and prints
whatever comes back. On every failure it prints nothing and exits 0, so Claude asks
as it always did. It is not the system's `nc`, which shuts its sending side when its
input ends, after which Cyclop could not tell a relay that still waits from one
that was killed. The hook is `PermissionRequest` and not `PreToolUse`, the
documented way to answer a question: Claude waits for `PreToolUse` before it draws
its own card, so a question would never show in Claude and Claude's notification
would never fire: with Cyclop closed the owner would never learn it waits.
`PermissionRequest` runs alongside Claude's card and the first answer wins. It takes
a question's answer too when the reply carries `updatedInput`, which is not in the
documentation: it was verified on Claude Code 2.1.295 and 2.1.296, and if an update
drops it a question is shown with Open in Claude and no buttons. A bare allow is
ignored for a question and for a plan, so a plan is approved by repeating the
tool's input. Always Allow sends back only the `addRules` entries of the request's
suggestions: the others (`setMode`, `addDirectories`) are for the session, and
sending the whole list switched it to accepting edits. A plan approved with a bare
allow would return the session to the mode it had before the plan, so Cyclop's own
approval always carries a `setMode` with the chosen mode and the destination
`session` (any other destination writes `permissions.defaultMode` into a settings
file).

A request goes away in three ways, any of them enough, and its text lives in memory
only. The relay's connection closes (the hook ended: timed out, or the session
died). The session's state changed after the request arrived and is no longer
waiting; the times are compared, because the session file can lag the request by a
fraction of a second. The session left the list. An answer given in Claude is the
case the first signal does not cover: Claude Code does not end the hook of a
request answered there, it stays until its timeout (the entry asks for a day) or
the end of the session, so for that case the state change and the list are the
signals, and Cyclop ends the hook itself by closing the relay. A decision printed
late is ignored.

Claude is not a typing tab, so the panel never takes the keyboard because Claude is
on screen, and pressing a button dims nothing. Own Answer… and Send Back with
Remarks… show a field and ask for the keyboard on that press; while a field is
shown, a click into the panel asks again, as it does for the teleprompter's empty
script. Return sends; Esc cancels and gives the keyboard back, and so do the
request going away, leaving the tab and the panel collapsing. The draft stays
across a collapse, kept in the store and not published: a change per keystroke
would be forwarded to the whole panel and rebuild the field, dropping its focus,
which is why the typing tabs' stores stay out of the header's forwarding too.

A request brings the panel out by itself, like a notification that carries its
buttons, and it is the one thing besides the pointer that does. Cyclop still makes
no sound and posts no notification; a switch in Settings (`openPanelForRequests` in
`config.json`, on by default, an older file loads it on) turns it off, and then
nothing comes out and the collapsed notch looks the same with and without a
request. The next opening after a request has arrived lands on Claude either way.

Which tab. The store publishes whether a request has arrived that the owner has
not seen: an arrival raises it, showing Claude in an open panel clears it, and the
last unseen request going away clears it. The view model does the rest. While every
panel is collapsed a rising flag makes it remember the tab and switch to Claude
then and there, so that the opening reads `openBodySize` from the Claude tab and is
at the tall height from its first frame; switching after the opening would show a
frame of the short body. Opening on Claude counts the requests as seen and forgets
the remembered tab: Claude is now the tab the owner "chose". A request answered in
Claude before the opening brings the remembered tab back, so one that came and went
moves nothing. A request arriving while a panel is open on another tab moves nothing
under the pointer; the switch waits for the last panel to collapse. A running
teleprompter pins its panel open, so the same rule leaves it alone, and with the tab
hidden nothing moves at all.

Whether to come out. The store also announces every arrival and the moment the last
request leaves. On an arrival the view model asks `RequestOpening.shouldOpen`: the
switch is on, the tab is on the rail, and no panel shows anything. A panel the owner
has open, a teleprompter included, is never moved or covered; the request stays
unseen, and the next opening lands on Claude as before. The controller opens one
screen, the one the pointer is on, else the main display, as a menu bar click
does. The open takes no keyboard and does not activate the app: the keyboard still
arrives only on a press on a field. The pointer's close rect is cut again at every
opening, because a tab that grew tall while the panel was collapsed was never
re-cut.

How long. Such a panel waits for the pointer. `PointerWatcher.awaitPointer()`
suspends the rule that closes an open panel whose pointer is away, until the
pointer is first inside the panel's close rect; from then on the ordinary rule
holds, so moving in and out collapses it as usual, and the request stays in the
tab, already seen. The panel also remembers that it came out for a request. When
the last request goes away (answered in the panel, answered in Claude, withdrawn,
the tab switched off, Disconnect) a panel that still has that mark folds, even with
the pointer on it, because answering means pointing at it. The mark goes with any
close and with a change to another tab, so a panel the owner opened by hover, or
went elsewhere in, obeys the pointer alone. Several requests keep it out until the
last is gone; there is no timeout.

**Approving a plan.** The hook's reply can only allow or deny; it cannot change a
session's model or effort, clear it or run `/compact`. What it can do is set the
mode. So a plan request carries a choice (context keep, compact or clear; model the
same or Sonnet; effort; mode), copied from the defaults in Settings and changed on
the card, and a pure function (`PlanChoice.route`) decides where it goes. *In place*
(context kept and the model not changed, or the session is on Sonnet already): the
reply allows with the mode; bypass is offered only when the session's process
arguments (`KERN_PROCARGS2`) carry a bypass flag, else it reads as accept edits.
*Hand-off*, anything else: the reply denies with `interrupt`, which ends the turn
and leaves the old session idle in plan mode, and the new session starts where the
plan was made (`ClaudeHandoff`, pure, builds the texts, the shell command and the
headless steps; `ClaudeStore` runs them). In a terminal the command goes to an
AppleScript as an argument, never into its source: a new window in Terminal (a tab
would need Accessibility), a new tab in the iTerm window that holds the session's
tty. For the Claude app and editors Cyclop runs `claude -p` itself in the session's
folder through `ClaudeRunning` (the session's own `claude` executable, else the
usual places; the environment without `CLAUDECODE` and the other session variables;
ten minutes a step), then opens `claude://resume?session=<id>` or the editor's own
link. The prepared session ends with a turn on the target model, because the app
reads the model from the transcript's tail. Every prep step that runs a model turn
is `--permission-mode default --max-turns 1` whatever mode was chosen (headless, it
cannot answer a permission request, so a tool call is refused, not run), the seed
prompt says to use no tool and answer only Ready, and `--model` and `--effort` stay
on the seed step (the `/compact` step has neither). The chosen effort and mode do
not carry to the app or the editor, so the card hides those two rows for that
route and says they are chosen in Claude; the terminal route runs interactively
in the chosen mode. The `claude` executable for an app or editor session is
resolved when the plan arrives. The session's current model comes from the last main-thread assistant record
in the last 256 KB of its transcript (`ClaudeHandoff.lastModel`), the only thing
read from one. Hand-off is not offered, and the card says so, when the plan has no
file, the request comes from a subagent, the host is a terminal other than
Terminal and iTerm or an editor with no link scheme, an app or editor session has
no `claude` executable, or a terminal command would hold a control character.
Values in the command are single-quoted (`'` as `'\''`, `\` as `'\\'`, the same
in POSIX shells and fish). The AppleScript runs off the main actor; only error
-1743 reads as Automation refused. Progress is a row per hand-off
above the session list, in memory, gone 8 seconds after it succeeded and kept until
dismissed when it failed. The store produces no UI strings: failures are enums and
the pane words them. ADR 0005 has the reasons and what was rejected.

**Settings.** Two pages behind a drawn switch (`NotchViewModel.settingsPage`, not
saved): Cyclop (General, Show in Panel, Displays, Configuration, Quit) and Tabs
(Screenshots, Snippets, Claude, with the plan defaults). The line in the Claude tab that leads to Settings
opens the Tabs page. The segmented controls are drawn
(`NotchSegmented`), because the system's segmented picker shows a grey selection in
a panel that never becomes key.

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
