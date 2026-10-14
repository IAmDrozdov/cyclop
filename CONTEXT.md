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
The tab the panel shows after launch: the first tab that is not a hidden tab, reading the left rail before the right. From then on the panel stays on whichever tab was chosen last, with one exception: a request that has arrived and is still waiting when the panel opens counts as choosing Claude. One answered in Claude before the opening moves nothing. With the switch Open Panel for Requests «Выезжать при запросе» on (the default), such a request opens the panel by itself, on Claude, when nothing is showing.
_Avoid_: home tab, start tab

**Pane**:
What a tab shows between the two rails.
_Avoid_: tab (the tab is the choice; the pane is its content)

**Dwell** (Dwell «Пауза»):
The pause that turns hovering into choosing: on the notch before the panel opens, and on a rail icon before the tab switches. The setting adjusts the pause on a physical notch only.
_Avoid_: hover delay

**Depth** (Depth «Глубина»):
How far into a physical notch the pointer has to be before the dwell starts counting, so a pointer that only brushes the edge opens nothing.
_Avoid_: sensitivity, inset, slack

**Typing tab**:
A tab that takes the keyboard on arrival without activating Cyclop: Translate, Currency and Snippets, and the Teleprompter while its script is empty. Claude is not one: it takes the keyboard only when the owner asks to type an answer. The keyboard goes back when the tab is left, the panel collapses or another app is clicked; Esc gives it back in no tab; in Translate, Currency and Snippets it clears the field.
_Avoid_: focus mode

**Pin**:
A running teleprompter holding the panel open on one display: the one exception to "open while the pointer is on it".
_Avoid_: sticky, keep-open

**Hidden tab** (Show in Panel «Показывать в панели», switched off):
A tab switched off in Settings: its icon leaves the rail and its background work stops.
_Avoid_: disabled tab; "hidden" alone, which clashes with Hide Contents

**Background work**:
What a tab keeps running while the panel is collapsed or on another tab, such as a poll or a timer. It runs only while the tab is on a rail, so hiding the tab stops it. A recording is a tab's own work in this sense: it goes on with the panel collapsed, and switching the tab off ends it and keeps what was recorded.
_Avoid_: service, daemon

**Menu bar icon** (Show Menu Bar Icon «Показывать иконку в меню-баре»):
The eye in the menu bar, holding Open Panel, Hide Contents and Quit.
_Avoid_: tray icon, status bar menu

### Tabs

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

**Translate** «Перевод»:
Offline translation between Russian and a second language, English or Polish, switched by a click on its column title. Text in Cyrillic goes to the second language and everything else to Russian; the direction comes from the script, not from language detection.

**Caffeine** «Кофеин»:
The tab that keeps the Mac from sleeping: by a caffeine session, or by lid-closed mode.
_Avoid_: Keep Awake (as its name), Amphetamine

**Meetings** «Встречи»:
The tab that records a call and keeps a journal of it. Everything stays on the Mac.
_Avoid_: recorder, dictaphone

**Meeting** «встреча»:
One row of the journal: a folder holding the audio of a call and its transcript.
_Avoid_: recording, session

**Recording** «запись»:
Only the process, from Start Recording to Stop. It is neither a file nor a journal row.

**Track** «дорожка»:
One of the two sides of a recording: the microphone, or the sound the Mac plays.

**Transcript** «транскрипт»:
The text of a meeting, in lines with a speaker and a time.

**Speaker** «говорящий»:
«Я» for the microphone track; «Собеседник A», «B», «C» for the voices told apart on the system track.

**Export** «Выгрузить»:
A copy of a meeting in Downloads; the meeting stays in the journal.

**Models** «модели»:
The files that recognise speech and tell voices apart, downloaded once by a button in the tab.

**Caffeine session** «сессия»:
A stretch during which the Mac does not fall asleep from idleness: indefinite, or for a chosen time. Only the system is kept awake; the screen still turns off and locks on its own schedule.
_Avoid_: timer (a timed session is one kind), keep-awake

**Lid-closed mode** (Stay Awake with the Lid Closed «Не спать с закрытой крышкой»):
A standing switch, independent of any caffeine session: while it is on and the lid is closed, the Mac stays awake, with or without an external display.
_Avoid_: clamshell mode (macOS's name for a closed Mac driving an external display), closed-display mode

**Currency** «Валюта»:
A two-sided converter between a chosen pair of currencies, on public daily rates; either side can be typed into.
_Avoid_: exchange

**Teleprompter** «Телесуфлёр»:
A script that scrolls under the camera at an adjustable speed. While it runs, the panel is pinned.
_Avoid_: prompter

**Script** «сценарий»:
The teleprompter's text.

**Claude** «Claude»:
The tab that shows the Claude sessions on this Mac and lets a request be answered without switching to Claude.
_Avoid_: Agents, Sessions (as its name), chat

**Claude session** «сессия»:
One running Claude Code on this Mac, started from the Claude app, an editor or a terminal. Chats on claude.ai and cloud sessions are not Claude sessions: Cyclop cannot see them.
_Avoid_: chat, agent, conversation; "session" alone outside the tab (a caffeine session is another thing)

**Working** «работает», **waiting** «ждёт», **idle** «свободна»:
The three states of a Claude session: busy on its own, stopped on a request, or done with its turn and ready for the owner's next message.
_Avoid_: running, finished, blocked

**Request** «запрос»:
What a waiting Claude session wants from the owner. One of three kinds: a permission «разрешение» to do one thing, such as run a command; a question «вопрос», with options and room for the owner's own words; a plan «план», to approve or send back with remarks.
_Avoid_: approval, prompt, dialog, card; "permission" alone in the docs, where it means a macOS permission

**Answer** «ответ»:
The owner's reply to a request, given in the panel or in Claude itself. The first one counts, and the other place stops asking.
_Avoid_: approve (one answer to one kind of request), decision

**Connection** (Connect to Claude «Подключить к Claude»):
What lets requests reach the panel: an entry Cyclop writes into Claude's settings at the press of a button and removes the same way. Without it the tab shows Claude sessions but cannot answer.
_Avoid_: hook (how it is made), integration, «соединение» (a network request)

**Open in Claude** «Открыть в Claude»:
Going to a Claude session in the app it runs in; in a terminal, to the session's own tab when macOS allows Automation, else only the terminal is brought forward.
_Avoid_: jump, focus

**Settings** «Настройки»:
The tab that cannot be hidden.

### Across tabs

**Hide Contents** «Скрывать содержимое»:
A menu bar option that covers what chosen sections show with a field of drifting dots, for screen sharing and streams.
_Avoid_: privacy mode, blur, spoiler

**Section**:
One tab's share of Hide Contents: clipboard, snippets or Claude. The Claude section covers the names of Claude sessions and the text of requests, and a covered request cannot be answered until it is revealed.
_Avoid_: category

**Reveal** (Show «Показать»):
Uncovering one covered item (a row) until the last open panel collapses.
_Avoid_: unhide

**Config file** (Show Config File «Показать файл конфигурации»):
The hand-editable file holding the settings that make sense on another Mac.
_Avoid_: preferences

**Broken file**:
A hand-edited snippets list or config file that no longer parses. Cyclop keeps what it has and refuses to write over it.
_Avoid_: corrupt file
