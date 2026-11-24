# Jengo Sessions

A small Windows app (PowerShell + WPF, no build step) that lists all your Claude Code sessions running in Windows Terminal windows.

- One row per session, named like its tab title. Click a row to bring that window to the front.
- Indicators per row: **A** listens on the agent board (`board.py wait`), **W** polls WhatsApp (`wa_team_poll`), **M** polls a meeting (`meeting_poll`).
- **Stash** button: asks that session to save its own handoff with the stash MCP tool (pastes a prompt into its window, after confirmation).
- Always on top, refreshes every 2 seconds.

## Run

    JengoSessions.cmd

Requires Windows 10/11, Windows PowerShell 5.1 and Windows Terminal. Sessions are read from `~/.claude/sessions`, titles from the session transcripts, windows via UI Automation.

The A/W/M detection looks for the Jengo-specific tools named above; adapt the patterns in `JengoSessions.ps1` for your own setup.

## Install (MSI)

Download `JengoSessions-1.0.0.msi` from the [latest release](https://github.com/scp-jengo/jengo-session-switcher/releases/latest) and run it. It installs per user (no admin needed) and adds a **Jengo Sessions** shortcut to the Start menu. Rebuild with `installer\build-msi.ps1 -Version x.y.z` (needs the WiX 5 dotnet tool).
