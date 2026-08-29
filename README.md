# omarchy-lan-mouse

An Omarchy bar widget for Lan Mouse: install and diagnose the Wayland-friendly LAN keyboard/mouse sharing service, manage its headless daemon, and open its GUI, configuration, and logs.

## Plugin identity

- **Plugin ID:** `io.github.matthewelgert.lan-mouse`
- **Kinds:** `bar-widget`
- **Default bar section:** `right`

## Install

```sh
omarchy plugin add https://github.com/mdelgert/omarchy-lan-mouse.git --enable
```

## What the widget does

- Shows a compact health indicator in the bar.
- Opens a control panel with these checks:
  - `lan-mouse` executable installed
  - `~/.config/lan-mouse/config.toml` exists
  - UFW rule for configured subnet/UDP port
  - `lan-mouse.service` installed/enabled/active in user systemd
- Supports periodic refresh while the panel is open.

### Status colors

- 🟢 green: package installed, firewall rule present, daemon active, config present
- 🟠 amber: setup incomplete or daemon stopped
- 🔴 red: Lan Mouse unavailable
- ⚪ gray: firewall check needs elevation

## Controls

- **Install & Configure**
  - Opens an authenticated terminal and runs only:
    - `sudo pacman -S --noconfirm lan-mouse`
    - `sudo ufw allow from <subnet> to any port <port> proto udp comment 'Lan Mouse'`
- **Install Service**
  - Installs `service/lan-mouse.service` to `~/.config/systemd/user/`
  - Runs `systemctl --user daemon-reload`
  - Runs `systemctl --user enable --now lan-mouse.service`
- **Start / Stop / Restart**
  - Uses `systemctl --user` for daemon lifecycle control
- **Launch GUI**
  - Runs `lan-mouse` (GTK pairing/authorization UI)
- **Open configuration**
  - Opens `$XDG_CONFIG_HOME/lan-mouse/config.toml` in `$EDITOR`
  - Creates a commented template if missing
- **Open logs**
  - Opens a terminal running:
    - `journalctl --user -u lan-mouse.service -f`

## Pairing and configuration notes

Use the Lan Mouse GUI to add peers and approve fingerprints. Authorized devices and related runtime configuration persist in `config.toml`.

The widget defaults to UDP port `4242` and subnet `192.168.100.0/24`, but both are editable settings. Inputs are validated as CIDR and port `1-65535`.

## Security model

This plugin is an independent integration and is not affiliated with Omarchy/Basecamp or Lan Mouse upstream.

Privileged package/firewall changes are not run silently in-process. They are launched in an authenticated terminal so privilege boundaries remain explicit and auditable. Headless runtime control is done with user systemd service commands.

## Uninstall

```sh
omarchy plugin remove io.github.matthewelgert.lan-mouse
systemctl --user disable --now lan-mouse.service || true
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/lan-mouse.service"
systemctl --user daemon-reload
```

## Credits

- [Lan Mouse](https://github.com/feschber/lan-mouse) by feschber
- Omarchy / Basecamp Quattro shell plugin architecture
