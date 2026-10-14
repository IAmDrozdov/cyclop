# Cyclop answers Claude's requests through a hook it installs and a local socket

The Claude tab lists the Claude sessions on the Mac and lets the owner answer a request (a permission, a question, a plan) from the panel. A session's state can be read from Claude Code's own files, but an answer has to get into the Claude Code process, and the one supported door is a `PermissionRequest` hook: a command Claude Code runs when it is about to ask, whose output it takes as the answer. So Cyclop keeps one hook entry in `~/.claude/settings.json`, written and removed only by a button in Settings, with a backup of the file, and listens on a Unix domain socket for the relay that entry starts. The hook runs alongside Claude's own card and the first answer wins: Claude's card and its notification stay, and with Cyclop closed or the tab switched off Claude asks as it always did.

Rejected:

- **Show and open, no hook.** The tab would list the sessions and open the waiting one in Claude. Claude's own notification already takes the owner there; answering without changing windows is what the tab adds.
- **A `PreToolUse` hook for questions**, the documented way to answer `AskUserQuestion`. Claude Code waits for it before showing its own card, so the question would not appear in Claude at all, and Claude's notification would not fire: with Cyclop closed the owner would never learn that a question is waiting. `PermissionRequest` answers a question too when the reply carries `updatedInput`. That is not in the documentation; it was verified on Claude Code 2.1.295 and 2.1.296.
- **The entry added by hand, or shipped as a Claude Code plugin.** Either keeps Cyclop out of another app's settings. The owner chose the button.
- **Pressing Claude's buttons through Accessibility.** It needs a macOS permission and breaks with every change of Claude's interface.

## Consequences

- `SECURITY.md` gains two exceptions to "listens to nothing and touches nothing that is not its own": a local socket, open to the owner's processes only and not to the network, and one entry in Claude's settings, changed only at the press of a button.
- The text of requests (commands, questions, plans) passes through Cyclop's memory and is never written to disk.
- A plan is approved only by a reply that repeats the tool's input. A bare allow is ignored for a plan, as it is for a question.
- Switching the tab off closes the socket and leaves the entry. An entry left behind after Cyclop is deleted points at nothing: Claude Code logs a hook error on each request and asks as usual, so the owner disconnects before deleting.
- If a Claude Code update drops the undocumented behaviour, a question is shown with Open in Claude and without answer buttons, and the `PreToolUse` path stays rejected for the reason above.
