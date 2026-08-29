# Implementation instructions for the coding agent

Build this as an Omarchy `bar-widget` with a panel. Follow the Omarchy plugin
development guide and clone a built-in widget with a panel as the UI reference.

## Required behavior

1. Run `lan-mouse daemon` as a child of the active Omarchy/Hyprland user
   session. Do not create, install, or control a systemd service.
2. Store one PID in `$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.pid`.
   Start is idempotent: verify the PID is alive and belongs to `lan-mouse daemon`
   before starting another process.
3. Stop only the verified stored PID; never use `pkill` or terminate processes
   found solely by name.
4. Health UI must separately report package availability, firewall-rule state,
   configuration-file availability, and daemon state.
5. The privileged Setup / Repair action must visibly request authentication in a
   terminal. It may run only the fixed package and UFW commands derived from
   validated subnet and port settings; never run arbitrary user-provided shell.
6. Provide panel buttons: Refresh, Setup / Repair, Launch GUI, Open Config,
   Open Logs, Start daemon, and Stop daemon.
7. Start from `omarchy plugin clone omarchy.clock --edit`, then replace the
   clone identity with `io.github.mdelgert.lan-mouse` before publishing.

## Source references

- https://omarchyplugins.com/develop.html
- https://github.com/basecamp/omarchy/blob/quattro/shell/README.md
- https://github.com/feschber/lan-mouse
