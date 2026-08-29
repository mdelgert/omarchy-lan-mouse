Copy this into a coding agent:

Develop the `omarchy-lan-mouse` Omarchy plugin from the attached `omarchy-lan-mouse-starter.zip`.

First, read these project files in full:

* `AGENT_TASK.md` — authoritative implementation requirements
* `README.md` — architecture, security, and product behavior
* `manifest.json` — intended plugin identity

Also use these upstream references before coding:

* [https://omarchyplugins.com/develop.html](https://omarchyplugins.com/develop.html)
* [https://github.com/basecamp/omarchy/blob/quattro/shell/README.md](https://github.com/basecamp/omarchy/blob/quattro/shell/README.md)
* [https://github.com/feschber/lan-mouse](https://github.com/feschber/lan-mouse)

Implement a polished Omarchy `bar-widget` with a panel that manages Lan Mouse.

Critical constraint: do not create or use a systemd service. Start `lan-mouse daemon` from the active Omarchy/Hyprland user session. Track only the process started by this plugin using `$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.pid`. Start must be idempotent; Stop must verify and terminate only that tracked process—never use `pkill`.

The plugin must provide:

* clear health status for package installation, configuration presence, UFW firewall rule, and daemon state
* Setup / Repair action that visibly requests authentication and runs only validated, fixed `pacman` and `ufw` commands
* Launch Lan Mouse GUI
* Open `~/.config/lan-mouse/config.toml` in the configured editor
* Open useful daemon logs
* Start, Stop, and Refresh controls

Use the Omarchy built-in clock widget/panel as the implementation pattern. Validate the finished plugin with `omarchy plugin validate` and `qmllint`, then provide a concise summary of changed files, validation results, and any remaining manual test steps.
