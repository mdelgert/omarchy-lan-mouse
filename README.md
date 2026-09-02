# Omarchy Lan Mouse

An [Omarchy](https://omarchy.org) bar widget for installing, diagnosing, and
controlling [Lan Mouse](https://github.com/feschber/lan-mouse) — a software KVM
switch that shares one keyboard and mouse across several computers over the
LAN — from the active Hyprland/Wayland session.

The bar icon says whether the daemon is up. The panel behind it says why not.

![The panel](docs/panel.png)

## What is Lan Mouse?

Lan Mouse is a **software KVM switch**: one keyboard and one mouse, shared
across several machines on your local network. Push the pointer off the edge of
one screen and it appears on the next computer, with keystrokes following it.
No USB switch, no extra cable, no video sharing — just input.

If you have used **Synergy**, **Barrier**, **Input Leap**, or **Deskflow**, this
is the same idea. If you have used **Apple Universal Control** between a Mac and
an iPad, it is that, for Linux. Where Lan Mouse differs is that it was written
for **Wayland** from the start rather than retrofitted from X11, which is why it
works on a modern **Hyprland** desktop where the older tools struggle.

It is cross-platform — Linux (Wayland and X11), Windows, and macOS — so a Linux
laptop can drive a Windows desktop and back again.

**What it is not:** it does not share your screen, your clipboard is not
included, and it is not remote desktop. It moves input between machines that
each have their own display.

## How it works on Wayland, wlroots, and Hyprland

Sharing input on Wayland is two separate problems, and Lan Mouse solves them
with two independent, swappable backends:

**Input capture** — noticing that your pointer hit the edge of the screen and
taking exclusive hold of the mouse and keyboard. Wayland deliberately forbids
applications from doing this the way X11 allowed, so it goes through a portal.
Backends: `input-capture-portal` (the `org.freedesktop.portal.InputCapture`
XDG desktop portal, backed by **libei**/**libEIS**), `layer-shell` (single-pixel
edge surfaces via `wlr-layer-shell`), `x11`, and `dummy`.

**Input emulation** — synthesizing that pointer motion and those keystrokes on
the receiving machine. Backends: `wlroots` (the
`wlr-virtual-pointer-unstable-v1` and `virtual-keyboard-unstable-v1` protocols),
`libei`, `xdp` (the freedesktop RemoteDesktop portal), `x11`, and `dummy`.

On a stock Omarchy/Hyprland box the daemon picks:

```text
[INFO input_capture]   using capture backend: input-capture-portal
[INFO input_emulation] using emulation backend: wlroots
```

Capture goes through **`xdg-desktop-portal-hyprland`**, which advertises
`org.freedesktop.impl.portal.InputCapture` — that package is what makes edge
capture work on Hyprland, and edge detection silently fails without it.
Emulation uses Hyprland's **wlroots** virtual-pointer and virtual-keyboard
protocols directly. The **Firewall** and **Package** rows in this plugin's panel
check the parts that commonly go wrong; if capture never triggers, confirm
`xdg-desktop-portal-hyprland` is installed.

Verified here on **Hyprland 0.56.2** with **lan-mouse 0.11.0** and
**xdg-desktop-portal-hyprland 1.4.1**.

Also supported upstream: **GNOME ≥ 45** and **KDE Plasma ≥ 6.1** (both via
libei), and most **wlroots** compositors including **Sway ≥ 1.8**, **Hyprland**,
and **Wayfire**. On X11, Lan Mouse can only *receive* input, not capture it.

### Network and security

Machines talk over **UDP port 4242** by default, encrypted with **DTLS** (via
WebRTC.rs). Pairing is by **TLS certificate fingerprint**: each machine shows a
fingerprint like `aa:bb:cc:dd:...`, and you authorize the other end's
fingerprint before input will cross. Authorized fingerprints live in
`~/.config/lan-mouse/config.toml` under `[authorized_fingerprints]`, and this
plugin's **Configuration** health row counts them, so "paired with 1 device" is
visible at a glance.

That UDP port is also why this plugin manages a UFW rule: without it the
handshake never completes across the network.

## Install

```bash
omarchy plugin add https://github.com/mdelgert/omarchy-lan-mouse.git
omarchy plugin enable io.github.mdelgert.lan-mouse --section right
```

Plugins land disabled so you can read the code before running it. To install
by hand instead, copy this directory to
`~/.config/omarchy/plugins/io.github.mdelgert.lan-mouse/`, then
`omarchy-shell shell rescanPlugins`.

## Uninstall

**Stop the daemon first.** Removing the plugin does not stop it — the daemon is
`setsid`-detached so it survives the shell, and once the plugin is gone there is
no button left to stop it with.

```bash
omarchy-shell io.github.mdelgert.lan-mouse stop
```

Then either hide it or delete it:

```bash
# Keep the files, take it off the bar. Re-enable any time.
omarchy plugin disable io.github.mdelgert.lan-mouse

# Or remove it entirely (disables it first, then deletes).
omarchy plugin remove io.github.mdelgert.lan-mouse --yes
```

A couple of things worth knowing about `remove`:

- If the plugin is a **git checkout** (the normal `omarchy plugin add` case) the
  directory is deleted outright.
- If you installed it **by hand**, the directory is *moved* to a hidden backup
  at `~/.config/omarchy/plugins/.io.github.mdelgert.lan-mouse.bak.<timestamp>`
  rather than deleted. Delete that too if you want it gone.

Widget settings live inline on the bar entry in
`~/.config/omarchy/shell.json` and go away with it. The runtime directory
(`$XDG_RUNTIME_DIR/omarchy-lan-mouse/`, holding the PID file and log) is cleared
at logout on its own.

### If the daemon was left running

The plugin is gone but the process is not. It is still a plain user process, so:

```bash
kill "$(cat "$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.pid")"
```

Or just log out — nothing here survives the session.

### Undoing what Setup / Repair changed

Uninstalling the plugin does **not** revert these; they are system state the
plugin only ever added on your explicit request. Undo them yourself if you are
done with Lan Mouse:

```bash
# Remove the firewall rule (same spec as the one that was added, minus the comment).
sudo ufw delete allow from 192.168.100.0/24 to any port 4242 proto udp

# Or pick it off the numbered list interactively.
sudo ufw status numbered
sudo ufw delete <number>

# Remove the package.
sudo pacman -Rns lan-mouse
```

Substitute your own `subnet` and `port` if you changed them from the defaults.

Lan Mouse's own configuration in `~/.config/lan-mouse/` belongs to Lan Mouse,
not to this plugin, and is left alone. It holds your TLS key
(`lan-mouse.pem`) and the fingerprints you authorized, so removing it means
re-pairing every device:

```bash
rm -rf ~/.config/lan-mouse    # only if you are done with Lan Mouse entirely
```

## Important architecture decision

Lan Mouse is launched by the plugin as the logged-in Omarchy user:

```sh
lan-mouse daemon
```

There is **no systemd service**, by design. The daemon needs the active
graphical session's Wayland socket and portal environment, which it inherits
by being started from the running shell. A user unit would be a second,
competing lifetime for something the session already owns.

That leaves the plugin responsible for knowing which process is its own. It
writes exactly one PID to:

```text
$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.pid
```

This location is per user and cleared at logout, so a PID from a previous
session can never be mistaken for a live daemon.

**Start is idempotent.** It verifies the recorded PID is a live
`lan-mouse daemon` before launching anything, so repeated clicks cannot
produce two daemons fighting over the same port.

**Start is serialized, and fails closed.** The bar instantiates a widget per
monitor, so a restore at login can fire two starts within milliseconds; a
`flock` on `$XDG_RUNTIME_DIR/omarchy-lan-mouse/start.lock` means only one gets
past the check above. If `flock` is missing, the lock file cannot be opened,
or the lock is still held when the ten-second timeout expires, the start is
abandoned with a message rather than run unguarded — the lock is the only
thing standing between two widgets and two daemons, so proceeding without it
is not a safe fallback. In the ordinary case the second caller simply waits,
takes the lock when the first finishes, and reports that the daemon is
already running.

**Stop is targeted.** It re-verifies the PID against `/proc` immediately
before every signal — command name, arguments, and owning UID — then sends
SIGTERM, waits, and escalates to SIGKILL only if needed. There is deliberately
no `pkill`, no `killall`, and no matching by process name.

A `lan-mouse` you started by hand is therefore *reported* but never touched:
the Daemon row reads "Running outside this plugin (PID …)" and Stop leaves it
alone.

### Remembering the switch

The PID file is cleared at logout on purpose, which is exactly why it cannot
also answer "did the user leave this switched on?". That intent is recorded
separately, and survives the reboot the PID file does not:

```text
$XDG_STATE_HOME/omarchy-lan-mouse/daemon-desired    # "on" or "off"
```

That file is written to a temporary file with an unpredictable name, created
`O_EXCL` under `umask 077`, and renamed into place. Both directions open the
file first and then judge the *descriptor* — a regular file you own, with a
single link, that no one else can write — rather than trusting the path,
because a name can be replaced between the check and the open. A symlink at
that path, a hardlinked file, or a state directory that is not yours and
private is refused: the write fails without disturbing the previous answer,
and the read falls back to `off` rather than following it. The directory
itself is created `0700` and verified.

Start writes `on` once the daemon is confirmed up; Stop writes `off` as soon
as you ask for it, whether or not the process goes quietly. At login the
panel runs `scripts/restore-daemon`, which starts the daemon again only if
that file says `on`, nothing is already running, and `lan-mouse` is
installed. A start that fails because the session is not ready yet is retried
twice, a few seconds apart.

Nothing is restored while the switch is off, so the plugin never starts a
daemon you did not ask for. Turn the restore off entirely with the
`restoreDaemonState` setting; the state is still recorded, just not acted on.

Until the daemon is up, the Daemon row reads "Switched on, but not running
right now" rather than pretending the switch and the process agree.

## Health

Four independent checks, each with its own verdict and its own fix:

| Row | Reports | Fixed by |
|-----|---------|----------|
| Package | Whether `lan-mouse` is on `PATH`, and its version | Setup / Repair |
| Configuration | Whether `~/.config/lan-mouse/config.toml` exists, and how many fingerprints it authorizes | Open config, or pair from the GUI |
| Firewall | Whether UFW admits udp/`port` from `subnet`, and whether UFW is enabled at all | Setup / Repair |
| Daemon | Whether the tracked process is alive, its uptime, and whether an untracked one exists | Start / Stop |

`scripts/health-check` emits this as one JSON object and is safe to run by
hand. Every probe is read-only and unprivileged — the panel polls it on a
timer, so it never prompts, installs, or changes state.

Its output is bounded where it is produced. The panel collects each script's
stdout and stderr whole into memory, and three of the values come from places
the plugin does not control — your `shell.json` settings, `lan-mouse
--version`, and the daemon's own log — so each is clipped to a fixed length
before it is reported, the list of untracked PIDs is capped with the rest
counted, and the log excerpt shown when a start fails is limited by line, by
column, and by total bytes, with control characters removed.

Reading UFW normally needs root. Rather than prompt on a timer, the check
tries `sudo -n ufw status` (exact, but only when sudo is already unlocked),
falls back to the world-readable `/etc/ufw/user.rules`, and reports `unknown`
rather than guessing when neither is available.

## Setup / Repair

Opens a floating terminal so the authentication prompt is visible and answered
by you, then runs three fixed commands:

```sh
sudo pacman -S --needed --noconfirm lan-mouse
sudo ufw allow from <subnet> to any port <port> proto udp comment 'Lan Mouse'
sudo ufw status verbose
```

Both steps are safe to repeat, which is what makes this a repair action as
well as a setup one: pacman skips an up-to-date package and ufw skips a rule
it already has. (`--needed` is the one deviation from a plain `-S`; without it
Repair would reinstall the package every time.)

The subnet and port are the only inputs, and they pass three gates before
reaching `ufw`:

1. `Model.js` validates them and refuses to build the command otherwise — an
   invalid setting disables the button rather than falling back to the default,
   because opening the firewall for a subnet you did not ask for is worse than
   doing nothing.
2. They are passed as an argv vector through `Util.shellQuote`, so they cross
   the terminal launcher as literal arguments rather than shell text.
3. `scripts/setup-repair` re-validates them, because a caller is not a trust
   boundary, and passes them to `pacman` and `ufw` as argv — never
   interpolated into a shell string.

The panel prints the exact rule it would add along the bottom edge, so the
privileged action is legible before it is triggered.

## Controls

| Action | Key | What it does |
|--------|-----|--------------|
| Start daemon | `S` | `lan-mouse daemon` in this session; idempotent |
| Stop daemon | `X` | Terminates only the tracked PID |
| Launch GUI | `G` | `lan-mouse`, for pairing and trust authorization |
| Open config | `C` | `config.toml` in your Omarchy editor |
| Open logs | `L` | Follows the daemon log |
| Setup / Repair | `U` | The authenticated terminal above |
| Refresh | `R` | Re-runs the health check |

Arrow keys move between the action buttons, Enter activates, Escape closes.

On the bar icon: left click opens the panel, right click refreshes, middle
click launches the GUI.

### Logs

With no systemd unit there is no journal to read, so `scripts/start-daemon`
redirects the daemon's stdout and stderr to
`$XDG_RUNTIME_DIR/omarchy-lan-mouse/lan-mouse.log` and rotates it past 1 MB.
Open logs tails that file.

## Settings

Set per instance in `~/.config/omarchy/shell.json`, or through
Setup > Plugins.

| Key | Default | Meaning |
|-----|---------|---------|
| `subnet` | `192.168.100.0/24` | IPv4 CIDR allowed through the firewall |
| `port` | `4242` | UDP port the daemon listens on |
| `refreshIntervalSec` | `30` | Health poll interval while the panel is closed |
| `restoreDaemonState` | `true` | Start the daemon at login when the switch was last left on |

The panel polls every 5 seconds while open so Start and Stop settle visibly.

## IPC

```bash
omarchy-shell io.github.mdelgert.lan-mouse status   # one-line summary
omarchy-shell io.github.mdelgert.lan-mouse toggle   # show/hide the panel
omarchy-shell io.github.mdelgert.lan-mouse start
omarchy-shell io.github.mdelgert.lan-mouse stop
omarchy-shell io.github.mdelgert.lan-mouse refresh
```

`open`, `close`, `gui`, `config`, `logs`, and `setup` are also available.

## Development

The shell only ever reads `~/.config/omarchy/plugins/<id>/`, never your
checkout, so editing this repo has no effect on its own. Install and reload in
one step:

```bash
scripts/dev-install            # copy + restart the shell
scripts/dev-install --enable   # ...and add it to the bar if it is not there
scripts/dev-install --no-restart

scripts/dev-uninstall          # take it off the bar, delete the installed copy, reload
scripts/dev-uninstall --yes    # skip the confirmation prompt
```

`dev-uninstall` is the counterpart, for testing a clean-slate install. It stops
the daemon first — the plugin's own `stop-daemon`, while that script still
exists — so removing the files cannot leave an orphaned `lan-mouse daemon` with
no UI to stop it. Then it disables the plugin, deletes
`~/.config/omarchy/plugins/<id>/`, and restarts the shell. Your checkout is
never touched, and `~/.config/lan-mouse/` is left alone so a reinstall does not
mean re-pairing every device.

It validates the working tree with `omarchy plugin validate` *before* touching
the installed copy, so a broken manifest leaves the running plugin alone.

**Why a full shell restart rather than the file watcher?** Saving under
`~/.config/omarchy/plugins/` does fire the shell's "plugin changed, reloading"
watcher, but that does not re-instantiate a bar widget the bar is already
holding: `BarWidget.qml` is mounted once per bar, and its bindings and
`IpcHandler` are fixed at instantiation. `omarchy-shell shell rescanPlugins`
does not pick those up either. Measured on this plugin:

| Action | Reload event | Change actually applied |
|--------|--------------|-------------------------|
| Save in the repo only | no | no |
| Copy into the plugins dir | yes | no |
| `omarchy-shell shell rescanPlugins` | — | no |
| `omarchy-restart-shell` | — | **yes** |

Two things that will waste your time otherwise:

- Use plain `cp`, never `cp -a`. `-a` preserves mtimes, and the watcher never
  notices a file whose timestamp did not move.
- Do **not** symlink the plugin directory at your checkout. The shell will load
  it, but the file watcher does not follow symlinks and
  `omarchy plugin validate` rejects it outright.

Clearing `~/.cache/quickshell/qmlcache` is not necessary; the restart is
sufficient. The daemon is `setsid`-detached, so restarting the shell does not
stop it.

To check the QML the way CI would, point `qmllint` at a directory containing a
`qs` symlink to the Omarchy shell so its `qs.Ui` / `qs.Commons` imports resolve:

```bash
mkdir -p /tmp/qmlroot && ln -sfn /usr/share/omarchy/shell /tmp/qmlroot/qs
qmllint -I /tmp/qmlroot -I /usr/lib/qt6/qml BarWidget.qml Panel.qml
```

`Model.js` is deliberately Qt-free so it can be exercised under node.

## Layout

```text
manifest.json      plugin identity, settings schema
BarWidget.qml      bar icon, IPC target, panel host
Panel.qml          health rows, actions, keyboard navigation
Model.js           validation, health parsing, severity — pure, node-testable
scripts/
  lib.sh           shared paths, validation, PID verification, desired state
  health-check     read-only JSON health report
  start-daemon     idempotent start
  stop-daemon      verified, targeted stop
  restore-daemon   start at login if the switch was left on
  setup-repair     the privileged terminal action
  open-logs        tails the daemon log
  dev-install      dev only: install into the plugins dir and reload
  dev-uninstall    dev only: remove the installed copy and reload
```

## Keywords

Searchable terms for anyone looking for this: omarchy plugin, omarchy bar
widget, omarchy shell, quickshell widget, lan-mouse, lan mouse, software KVM
switch, KVM switch software, keyboard and mouse sharing, share mouse between
computers, share keyboard between computers, mouse sharing Linux, multi-computer
mouse, Synergy alternative, Barrier alternative, Input Leap alternative, Deskflow
alternative, open source Universal Control, Hyprland, Hyprland plugin, wlroots,
Wayland, Wayland input sharing, wlr-virtual-pointer, virtual-keyboard-unstable-v1,
wlr-layer-shell, libei, libEIS, xdg-desktop-portal, xdg-desktop-portal-hyprland,
InputCapture portal, RemoteDesktop portal, Arch Linux, Omarchy, UFW, DTLS,
seamless mouse across monitors, cross-platform mouse sharing.

If you maintain a fork, the matching GitHub repository topics are:
`omarchy` `omarchy-plugin` `hyprland` `wayland` `wlroots` `quickshell`
`lan-mouse` `kvm-switch` `input-sharing` `synergy-alternative` `archlinux` `qml`.

## Credits

- [Lan Mouse](https://github.com/feschber/lan-mouse) by feschber.
- [Omarchy](https://github.com/basecamp/omarchy) by Basecamp.
- [Omarchy plugin development guide](https://omarchyplugins.com/develop.html).

This is an independent integration and is not affiliated with either upstream
project.
