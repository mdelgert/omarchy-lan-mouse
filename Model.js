.pragma library

function statusGlyph(state) {
  if (state === "green") return "🟢"
  if (state === "amber") return "🟠"
  if (state === "red") return "🔴"
  return "⚪"
}

function statusLabel(state) {
  if (state === "green") return "Healthy"
  if (state === "amber") return "Needs setup"
  if (state === "red") return "Unavailable"
  return "Unknown"
}

function parseKeyValue(raw) {
  var out = {}
  var lines = String(raw || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i += 1) {
    var line = lines[i]
    if (!line) continue
    var idx = line.indexOf("=")
    if (idx <= 0) continue
    out[line.slice(0, idx)] = line.slice(idx + 1)
  }
  return out
}

function asBool(value) {
  return value === "1" || value === "true"
}

function asNumber(value, fallback) {
  var n = Number(value)
  return Number.isFinite(n) ? n : fallback
}

function validPort(value) {
  var n = Number(value)
  return Number.isInteger(n) && n >= 1 && n <= 65535
}

function validCidr(value) {
  var m = String(value).match(/^(\d{1,3})(?:\.(\d{1,3})){3}\/(\d|[12]\d|3[0-2])$/)
  if (!m) return false

  var parts = String(value).split("/")[0].split(".")
  for (var i = 0; i < parts.length; i += 1) {
    var n = Number(parts[i])
    if (!Number.isInteger(n) || n < 0 || n > 255) return false
  }
  return true
}

function serviceSummary(health) {
  if (asBool(health.service_active)) return "Active"
  if (asBool(health.service_enabled)) return "Enabled (stopped)"
  if (asBool(health.service_installed)) return "Installed"
  return "Missing"
}
