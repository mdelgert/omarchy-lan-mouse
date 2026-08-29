// Pure state and validation helpers for the Lan Mouse widget and its panel.
//
// Everything here is Qt-free so it can be reasoned about (and run under node)
// on its own: the QML owns rendering and process launching, this file owns
// what the health payload means and what counts as a legal setting.
//
// The validation functions are the first of three gates a subnet or port
// passes before it can reach `ufw`. This one keeps a bad value from ever
// being built into a command; Util.shellQuote keeps the argument intact
// across the terminal launcher; scripts/lib.sh re-validates because a caller
// is not a trust boundary.

var DEFAULT_SUBNET = "192.168.100.0/24"
var DEFAULT_PORT = 4242
var DEFAULT_REFRESH_SEC = 30

// Polling while the panel is open is about responsiveness after Start/Stop,
// not about the bar icon, so it runs faster than the configured interval.
var OPEN_REFRESH_SEC = 5

// ---- Settings validation ------------------------------------------------

function isValidPort(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  if (!/^[0-9]{1,5}$/.test(text)) return false
  var n = parseInt(text, 10)
  return n >= 1 && n <= 65535
}

// IPv4 CIDR only, which is what `ufw allow from ...` takes here. Rejects
// out-of-range octets and prefixes rather than leaving that to ufw.
function isValidSubnet(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  var match = /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\/([0-9]{1,2})$/.exec(text)
  if (!match) return false
  for (var i = 1; i <= 4; i++) {
    if (parseInt(match[i], 10) > 255) return false
  }
  return parseInt(match[5], 10) <= 32
}

function normalizedPort(value) {
  return isValidPort(value) ? parseInt(String(value).trim(), 10) : DEFAULT_PORT
}

function normalizedSubnet(value) {
  return isValidSubnet(value) ? String(value).trim() : DEFAULT_SUBNET
}

function normalizedRefreshSec(value) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) return DEFAULT_REFRESH_SEC
  return Math.max(5, Math.min(3600, n))
}

// The settings actually in force, plus whether the stored ones were usable.
// The panel shows the fallback notice; it never silently substitutes.
function resolvedSettings(subnetSetting, portSetting) {
  return {
    subnet: normalizedSubnet(subnetSetting),
    port: normalizedPort(portSetting),
    subnetValid: isValidSubnet(subnetSetting),
    portValid: isValidPort(portSetting)
  }
}

// ---- Paths --------------------------------------------------------------

// Qt.resolvedUrl() hands back a percent-encoded file:// URL; scripts need a
// plain filesystem path. Non-file URLs yield "" so a caller never builds a
// command out of something that is not a path.
function pathFromUrl(url) {
  var text = String(url || "")
  if (text.indexOf("file://") !== 0) return ""
  text = text.slice("file://".length)
  try {
    text = decodeURIComponent(text)
  } catch (e) {
    return ""
  }
  while (text.length > 1 && text.charAt(text.length - 1) === "/") {
    text = text.slice(0, -1)
  }
  return text
}

// ---- Health payload -----------------------------------------------------

function emptySection(state, detail) {
  return { state: state || "unknown", detail: detail || "", }
}

function emptyHealth() {
  return {
    schema: 0,
    loaded: false,
    subnet: DEFAULT_SUBNET,
    port: DEFAULT_PORT,
    settingsValid: true,
    settingsDetail: "",
    paths: { config: "", pid: "", log: "" },
    package: emptySection("unknown", "Checking..."),
    config: emptySection("unknown", "Checking..."),
    firewall: emptySection("unknown", "Checking..."),
    daemon: { state: "unknown", detail: "Checking...", pid: 0, foreignPids: [], logPresent: false, logSize: 0 }
  }
}

function section(raw, key) {
  var value = raw && raw[key] ? raw[key] : null
  if (!value) return emptySection("unknown", "")
  return {
    state: String(value.state || "unknown"),
    detail: String(value.detail || "")
  }
}

// Normalize whatever scripts/health-check produced into the shape the panel
// binds against. A truncated or non-JSON payload degrades to "unknown"
// everywhere rather than throwing inside a binding.
function parseHealth(raw) {
  var data = null
  if (typeof raw === "string") {
    var text = raw.trim()
    if (!text) return emptyHealth()
    try {
      data = JSON.parse(text)
    } catch (e) {
      return emptyHealth()
    }
  } else if (raw && typeof raw === "object") {
    data = raw
  }
  if (!data || typeof data !== "object") return emptyHealth()

  var daemonRaw = data.daemon || {}
  var pathsRaw = data.paths || {}
  var foreign = []
  if (daemonRaw.foreignPids && daemonRaw.foreignPids.length) {
    for (var i = 0; i < daemonRaw.foreignPids.length; i++) {
      var n = parseInt(daemonRaw.foreignPids[i], 10)
      if (isFinite(n) && n > 0) foreign.push(n)
    }
  }

  return {
    schema: parseInt(data.schema, 10) || 0,
    loaded: true,
    subnet: String(data.subnet || DEFAULT_SUBNET),
    port: parseInt(data.port, 10) || DEFAULT_PORT,
    settingsValid: data.settingsValid !== false,
    settingsDetail: String(data.settingsDetail || ""),
    paths: {
      config: String(pathsRaw.config || ""),
      pid: String(pathsRaw.pid || ""),
      log: String(pathsRaw.log || "")
    },
    package: section(data, "package"),
    config: section(data, "config"),
    firewall: section(data, "firewall"),
    daemon: {
      state: String(daemonRaw.state || "unknown"),
      detail: String(daemonRaw.detail || ""),
      pid: parseInt(daemonRaw.pid, 10) || 0,
      foreignPids: foreign,
      logPresent: daemonRaw.logPresent === true,
      logSize: parseInt(daemonRaw.logSize, 10) || 0
    }
  }
}

// ---- Severity -----------------------------------------------------------
//
// Five tiers, because "the daemon is stopped" and "the package is missing"
// are not the same news. `idle` is a resting state the user chose, not a
// fault, so it must not paint like one.

function packageTier(state) {
  if (state === "ok") return "ok"
  if (state === "missing") return "bad"
  return "unknown"
}

function configTier(state) {
  if (state === "ok") return "ok"
  if (state === "missing") return "warn"
  return "unknown"
}

function firewallTier(state) {
  if (state === "ok") return "ok"
  if (state === "missing" || state === "inactive" || state === "absent") return "warn"
  return "unknown"
}

function daemonTier(state) {
  if (state === "running") return "ok"
  if (state === "foreign") return "warn"
  if (state === "stopped") return "idle"
  return "unknown"
}

function tierFor(health, key) {
  if (!health || !health.loaded) return "unknown"
  if (key === "package") return packageTier(health.package.state)
  if (key === "config") return configTier(health.config.state)
  if (key === "firewall") return firewallTier(health.firewall.state)
  if (key === "daemon") return daemonTier(health.daemon.state)
  return "unknown"
}

// What the bar icon reflects. The package being absent outranks everything —
// nothing else can be true without it.
function overallTier(health) {
  if (!health || !health.loaded) return "unknown"
  if (packageTier(health.package.state) === "bad") return "bad"
  if (health.settingsValid === false) return "warn"
  if (daemonTier(health.daemon.state) === "warn") return "warn"
  if (health.daemon.state === "running") {
    return firewallTier(health.firewall.state) === "warn" ? "warn" : "ok"
  }
  return "idle"
}

function daemonRunning(health) {
  return !!(health && health.loaded && health.daemon.state === "running")
}

// Start is pointless without the package, and lan-mouse refuses to run a
// second instance, so an unmanaged daemon blocks it too.
function canStart(health) {
  if (!health || !health.loaded) return false
  if (health.package.state !== "ok") return false
  return health.daemon.state !== "running" && health.daemon.state !== "foreign"
}

function canStop(health) {
  return daemonRunning(health)
}

// ---- Labels -------------------------------------------------------------

function statusLine(health) {
  if (!health || !health.loaded) return "Checking Lan Mouse..."
  if (health.package.state !== "ok") return "Lan Mouse is not installed"
  if (health.daemon.state === "running") return health.daemon.detail
  if (health.daemon.state === "foreign") return "Daemon running outside this plugin"
  return "Daemon stopped"
}

function tooltipText(health) {
  if (!health || !health.loaded) return "Lan Mouse — checking..."
  var lines = ["Lan Mouse — " + statusLine(health)]
  if (health.firewall.state !== "ok") lines.push("Firewall: " + health.firewall.detail)
  if (health.config.state !== "ok") lines.push("Config: " + health.config.detail)
  return lines.join("\n")
}

function versionLabel(health) {
  if (!health || !health.loaded || health.package.state !== "ok") return ""
  // "lan-mouse 0.11.0" reads as just the number beside the title.
  var detail = String(health.package.detail || "")
  var match = /(\d+\.\d+(?:\.\d+)?)/.exec(detail)
  return match ? "v" + match[1] : ""
}

// The fixed command the Setup / Repair terminal will run, shown to the user
// before they trigger it. Built from validated values only.
function ufwRuleText(subnet, port) {
  return "ufw allow from " + normalizedSubnet(subnet) + " to any port " + normalizedPort(port) + " proto udp"
}
