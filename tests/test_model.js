// Run with node tests/test_model.js.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const model = vm.createContext({})
vm.runInContext(fs.readFileSync(path.join(__dirname, "../Model.js"), "utf8"), model)

assert.equal(model.resolvedSettings("auto", 4242, "192.168.1.0/24").subnet, "192.168.1.0/24")
assert.equal(model.resolvedSettings("auto", 4242, "").subnetValid, false)
assert.equal(model.resolvedSettings("10.0.0.0/24", 4242, "192.168.1.0/24").subnet, "10.0.0.0/24")
assert.equal(model.resolvedSettings("invalid", 4242, "192.168.1.0/24").subnetValid, false)
assert.equal(model.parseHealth('{"subnet":"","settingsValid":false}').subnet, "")
assert.equal(model.ufwRuleText("", 4242), "")
assert.equal(model.ufwRuleText("auto", 4242), "")
assert.equal(model.ufwRuleText("192.168.1.0/24", 4242),
  "ufw allow from 192.168.1.0/24 to any port 4242 proto udp")
console.log("Model subnet regression checks passed")
