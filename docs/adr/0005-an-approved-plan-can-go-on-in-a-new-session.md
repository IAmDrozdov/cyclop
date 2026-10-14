# An approved plan can go on in a new session, started by Cyclop where the plan was made

The owner's routine after a plan is approved is "/clear, /model sonnet, /effort medium, implement from the plan file": a small context on a cheaper model. A `PermissionRequest` reply cannot do any of it. It can only allow (with `updatedInput` and `updatedPermissions`) or deny (with `message` and `interrupt`); `model`, `effort`, `clearContext` and `compact` are ignored without an error, and nothing outside a session can switch its model or effort or run `/compact` in it (verified on Claude Code 2.1.295 and 2.1.299). What the reply can do is set the mode: `updatedPermissions` with `setMode` and destination `session`. `bypassPermissions` takes effect only if the session's process was started with one of the bypass flags; otherwise it is dropped silently.

So the plan card has a choice (context, model, effort, mode), and its route is decided by the choice and by what is known about the session:

- **In place**: context kept and the model unchanged (or the session is on Sonnet already). Cyclop approves with the chosen mode. Bypass is offered only when the process arguments show a bypass flag, and falls back to accept edits otherwise.
- **Hand-off**: anything else. Cyclop denies with `interrupt` (the old session stays idle in plan mode), then starts a new session **where the plan was made**: a terminal session in the same terminal app (Terminal opens a window, iTerm a tab, by AppleScript; one shell command), a Claude app or editor session prepared by Cyclop with headless `claude -p` runs in the session's folder and then opened by `claude://resume?session=<id>` or the editor's own link. The new session's prompt names the plan file and the planning transcript; a prepared one ends with a turn that answers "Ready" and waits, because the app takes the model and the mode from the transcript's tail and nothing is sent without the owner. That turn is enforced, not only requested: every prep step that runs a model turn uses `--max-turns 1` and `--settings` with a `PreToolUse` hook that refuses every tool in any mode, bypass included (`--max-turns 1` alone still runs the first turn's tools), and the seed prompt tells the model to use no tool. Its mode is `ClaudeHandoff.preparedMode`: the chosen one for the app, with bypass as accept edits as the app opens it anyway, and default for the editor. `--model`, `--effort` and `--permission-mode` stay on the seed step; the `/compact` step has none of them. The terminal route is interactive and runs in the chosen mode.

The session's current model, which the hook payload does not carry, is read from the tail of its transcript: only `message.model` of the last main-thread assistant record. Defaults for the choice (clear, Sonnet, medium, bypass) live in `config.json` and Settings.

Rejected:

- **Typing `/clear`, `/model` and `/effort` into the terminal tab.** It works only in terminals, depends on timing and on what the prompt happens to hold, and the Claude app and the editors have no such door.
- **The Claude app's own session tools.** They are reachable from inside a session, not from another process.
- **Prefill-only links.** `claude://` and the editor link can open a session or prefill text, but neither picks a model.
- **A new tab in Terminal.** It needs GUI scripting, that is Accessibility, which the app does not ask for; `do script` opens a window instead.
- **Resuming the live session itself.** Two writers branch the transcript; every new session is a fork (`--fork-session`) or a fresh one.

## Consequences

- Cyclop starts `claude` processes, which talk to Anthropic on the owner's account and spend tokens (compact of a Claude app or editor session may miss the session's prompt cache, which is not measured; in a terminal the fork runs in the same CLI and can reuse it; keep with Sonnet reads the whole history uncached on Sonnet; this is why clear is the default). They run without `CLAUDECODE` and the other `CLAUDE_CODE_*` variables, or they would behave as children of a session and not save a transcript.
- Automation of Terminal and iTerm, already asked for by Open in Claude, now also opens a window or tab and types a command. No new macOS permission and no new request from Cyclop itself.
- Cyclop reads one more thing from a transcript, the model name of its last record, and the process arguments of a session.
- A reply can switch a session into bypass permissions. It happens only on the owner's press, with the session's own flag allowing it.
- A session handed off to the Claude app cannot carry the chosen effort, and bypass arrives as accept edits: the app takes the mode from the transcript's last turn and drops the effort. The prep turn runs in the chosen mode (bypass as accept edits) behind a hook that refuses every tool, so the plan card keeps the Mode row for the app, hides Effort and says it is chosen in Claude. The editor's import is unverified, so its prep turn asks and the card hides both rows. This is not worked around.
- For the app and editor the `claude` executable is resolved when the plan arrives; without one the hand-off is not offered and Approve works in place, so a plan is never denied and then lost.
- A terminal hand-off is not offered when the plan file, folder, session id or transcript path holds a control character, which the terminal's line editor would act on even inside quotes.
- A hand-off can fail (Automation refused with error -1743, any other terminal script failure, a session made but with no link to open it, a step that exits non-zero or takes more than ten minutes). The row says why; for a terminal it offers the command to copy. Nothing is retried.
- Not verified here: the iTerm script (iTerm is not installed on the development Mac), Terminal.app's `do script` window running the quoted command, and the editor link opening a session made by `claude -p`.
- `SECURITY.md` says all of this in Russian.
