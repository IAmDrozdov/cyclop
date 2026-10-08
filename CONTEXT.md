# Cyclop

Cyclop turns the top centre of a Mac's screen (the notch, or one it draws) into a panel of small tools that opens while the pointer is on it and collapses when the pointer leaves. A name in parentheses is the label of a control or setting, English «Russian»; a bare «…» is the Russian word for the term in the Russian UI and docs.

## Language

### The panel

**Notch**:
The black shape at the top centre of a display that the panel grows out of: a physical notch or a drawn notch.
_Avoid_: island, cutout (for the drawn one)

**Physical notch**:
The camera cutout of a MacBook display; nothing is painted over it while the panel is collapsed.
_Avoid_: real notch, hole

**Drawn notch**:
The notch Cyclop draws on a display without a cutout: a thin strip along the top edge, or the full menu bar height when Full-Height Notch Without a Cutout «Высокая чёлка на экранах без выреза» is on.
_Avoid_: fake notch, synthetic notch

**Panel** (Open Panel «Открыть панель»):
The surface that opens downward from the notch: one per display, or one on the notched (else the main) display when Show on All Displays «Показывать на всех дисплеях» is off. All panels show the same tab.
_Avoid_: window, popover, island

**Open**:
The panel's state while it is out below the notch, showing the rails and a pane.
_Avoid_: expanded, unfolded

**Collapsed**:
The panel's resting state, when only the notch shows.
_Avoid_: folded, closed, hidden

**Header**:
The strip of the open panel level with the notch: the tab's title and a small per-tab badge. Nothing in it reacts to clicks.
_Avoid_: title bar

**Rail**:
A column of tab icons beside the pane. The panel has a left rail and a right rail.
_Avoid_: sidebar, tab bar, column

**Tab** «Вкладка»:
One of the things the panel does, chosen from a rail. All displays share the current tab.
_Avoid_: section (that belongs to Hide Contents), page, mode

**Default tab**:
The tab the panel shows after launch: the first tab that is not a hidden tab, reading the left rail before the right. From then on the panel stays on whichever tab was chosen last.
_Avoid_: home tab, start tab

**Pane**:
What a tab shows between the two rails.
_Avoid_: tab (the tab is the choice; the pane is its content)

**Dwell**:
The pause that turns hovering into choosing: on the notch before the panel opens, and on a rail icon before the tab switches.
_Avoid_: hover delay

**Typing tab**:
A tab that takes the keyboard on arrival without activating Cyclop: Translate, Currency and Snippets, and the Teleprompter while its script is empty. The keyboard goes back when the tab is left, the panel collapses or another app is clicked; Esc gives it back in no tab; in Translate, Currency and Snippets it clears the field.
_Avoid_: focus mode

**Pin**:
A running teleprompter holding the panel open on one display: the one exception to "open while the pointer is on it".
_Avoid_: sticky, keep-open

**Hidden tab** (Show in Panel «Показывать в панели», switched off):
A tab switched off in Settings: its icon leaves the rail and its background work stops.
_Avoid_: disabled tab; "hidden" alone, which clashes with Hide Contents

**Background work**:
What a tab keeps running while the panel is collapsed or on another tab, such as a poll, an observer or the helper. It runs only while the tab is on a rail, so hiding the tab stops it.
_Avoid_: service, daemon

**Menu bar icon** (Show Menu Bar Icon «Показывать иконку в меню-баре»):
The eye in the menu bar, holding Open Panel, Hide Contents and Quit.
_Avoid_: tray icon, status bar menu

### Tabs

**Music** «Музыка»:
What macOS is playing right now, from any player or browser tab, with artwork, a scrubber and transport buttons.
_Avoid_: Media, player tab, Now Playing tab

**Now Playing**:
The system-wide record of the current playback session that macOS keeps; the Music tab's source.
_Avoid_: media session

**Now Playing helper** «хелпер»:
A separate process that reads Now Playing for the app, because macOS answers those queries only to its own trusted binaries.
_Avoid_: perl helper, media helper

**Scripting fallback** «запасной путь»:
The Music tab's second route, used only when the helper is unavailable: it scripts Apple Music or Spotify directly, or sends plain media keys when neither is active. It needs the Automation permission, and Accessibility for the media keys.
_Avoid_: legacy mode

**Scrubber**:
The Music pane's progress bar; dragging it seeks.
_Avoid_: slider, timeline

**Shelf** «Полка»:
Files dropped on the notch, held as references (never copies); dragging a card out hands the file on and leaves the card. Clipboard screenshots and new files in the watched screenshots folder land here too.
_Avoid_: tray, drop zone

**Clipboard** «Буфер»:
The recent history of things copied anywhere on the Mac; clicking an entry copies it again. Copies from password managers never enter it.
_Avoid_: pasteboard history

**Clipboard screenshot** (Save Clipboard Screenshots «Сохранять скриншоты из буфера»):
An image that arrives on the clipboard, an iPhone screenshot copied over Universal Clipboard included. It is saved to the screenshot vault and put on the shelf instead of into the clipboard history.

**Screenshot vault**:
The folder Cyclop saves clipboard screenshots to. Nothing in it is deleted automatically.
_Avoid_: Screenshots folder (the UI also uses that name for the watched screenshots folder)

**Watched screenshots folder** (Watch Screenshots Folder «Отслеживать папку снимков»):
An opt-in folder where macOS saves ⌘⇧3 and ⌘⇧4 screenshots; new files in it are put on the shelf.

**Snippet** (the Snippets tab «Заготовки»):
One entry in a short, hand-kept list of text worth not retyping, such as an address, with an optional label; clicking it copies the text. The list is a file that can also be edited by hand.
_Avoid_: template, favourite, pinned clip

**Calendar** «Календарь»:
The next meetings within a week, with a countdown to the first one and a Join button.
_Avoid_: agenda, events, schedule

**Meeting** «встреча»:
A calendar event the Calendar tab shows: timed rather than all-day, not cancelled, and within the week ahead.
_Avoid_: event

**Join button** (Join «Подключиться»):
Opens the video-call link found in a meeting, for known call services only.

**Translate** «Перевод»:
Offline translation between English and Russian. Text in Cyrillic goes to English and everything else to Russian; the direction comes from the script, not from language detection.

**Currency** «Валюта»:
A two-sided converter between a chosen pair of currencies, on public daily rates; either side can be typed into.
_Avoid_: exchange

**Teleprompter** «Телесуфлёр»:
A script that scrolls under the camera at an adjustable speed. While it runs, the panel is pinned.
_Avoid_: prompter

**Script** «сценарий»:
The teleprompter's text.

**Utilities** «Утилиты»:
The tab for rarely needed modes; today it holds the keyboard lock.
_Avoid_: Tools (as its name)

**Keyboard lock** (Lock Keyboard «Заблокировать клавиатуру»):
A cleaning mode that swallows every key press and click so the keyboard and trackpad can be wiped. It needs the Accessibility permission.
_Avoid_: input lock

**Cleaning overlay**:
The black windows over every display while the keyboard lock is on.

**Settings** «Настройки»:
The tab that cannot be hidden.

### Across tabs

**Hide Contents** «Скрывать содержимое»:
A menu bar option that covers what chosen sections show with a field of drifting dots, for screen sharing and streams.
_Avoid_: privacy mode, blur, spoiler

**Section**:
One tab's share of Hide Contents: clipboard, snippets or calendar.
_Avoid_: category

**Reveal** (Show «Показать»):
Uncovering one covered item (a row, or the whole Calendar tab) until the last open panel collapses.
_Avoid_: unhide

**Config file** (Show Config File «Показать файл конфигурации»):
The hand-editable file holding the settings that make sense on another Mac.
_Avoid_: preferences

**Broken file**:
A hand-edited snippets list or config file that no longer parses. Cyclop keeps what it has and refuses to write over it.
_Avoid_: corrupt file
