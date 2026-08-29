# Omarchy Lan Mouse

An Omarchy bar widget for installing, diagnosing, and controlling the Lan Mouse
keyboard and mouse-sharing daemon from the active Hyprland/Wayland session.

## Important architecture decision

Lan Mouse is launched by the plugin as the logged-in Omarchy user:

```sh
lan-mouse daemon
```

Do **not** create a systemd service for this plugin. The process needs the
active graphical session's environment and should be managed by the plugin.

The plugin writes its runtime state to:

```text
$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.pid
```

This location is per user and is cleared at logout. Start must check the saved
PID before launching a second daemon. Stop must only terminate the saved,
verified `lan-mouse daemon` process; it must not use broad `pkill` matching.

## Setup behavior

The Setup button opens an authenticated terminal to run:

```sh
sudo pacman -S --noconfirm lan-mouse
sudo ufw allow from 192.168.100.0/24 to any port 4242 proto udp comment 'Lan Mouse'
sudo ufw status verbose
```

The subnet and port are plugin settings. Validate them before building the
commands. Do not accept arbitrary shell commands.

## Controls

- Health: package, configuration, firewall rule, and tracked daemon status.
- Setup / Repair: install the package and add the requested UFW rule.
- Launch GUI: runs `lan-mouse` for pairing and trust authorization.
- Open configuration: opens `~/.config/lan-mouse/config.toml` in `$EDITOR`.
- Open logs: opens a terminal with the plugin's daemon log output.
- Start / Stop daemon: runs the scripts in `scripts/`.

## Credits

- [Lan Mouse](https://github.com/feschber/lan-mouse) by feschber.
- [Omarchy](https://github.com/basecamp/omarchy) by Basecamp.
- [Omarchy plugin development guide](https://omarchyplugins.com/develop.html).

This is an independent integration and is not affiliated with either upstream project.
