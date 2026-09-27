# Windows setup files (Appendix C of "It Ran While I Slept")

Two files that make one Claude Code project ask before acting and refuse file writes outside the project folder.

- `.claude/settings.json` sets ask-first mode (`"defaultMode": "default"`), denies reading `.env` files, and registers the write guard.
- `.claude/hooks/guard-writes.ps1` blocks Claude's file-writing tools (Write, Edit, NotebookEdit) from writing outside the project. It allows one extra place, `%USERPROFILE%\.claude\plans`, where plan mode saves its plans.

## Use

Copy the `.claude` folder into your project folder. If your project already has a `.claude\settings.json`, merge by hand instead of overwriting it. Start `claude` again: the status line should say manual mode, and `/hooks` should list one hook.

Then test both ways: ask Claude to write a file on your Desktop (the guard should refuse it), then inside the project (it should pass the guard and ask your permission).

## Limits

- The guard checks the file-writing tools only. Commands run through PowerShell or Bash are not checked by it; ask-first mode covers those.
- A junction or symbolic link inside the project that points outside it is not caught.
- Claude Code's sandbox does not run on native Windows, so these settings and your permission mode are the whole fence.

Checked in September 2026 on Claude Code 2.1.283 on Windows 10 and 11. Remove everything by deleting the project's `.claude` folder.
