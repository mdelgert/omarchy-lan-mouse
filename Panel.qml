import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  signal healthChangedExternally(var nextHealth)

  property var bar
  property var settings: ({})
  property var health: ({ state: "gray", message: "Loading..." })
  property Item anchorItem: null

  property string subnet: setting("subnet", "192.168.100.0/24")
  property int port: Model.asNumber(setting("port", 4242), 4242)
  property string errorText: ""

  readonly property bool opened: panel.open

  function setting(key, fallback) {
    return settings && settings[key] !== undefined ? settings[key] : fallback
  }

  function localPath(relativePath) {
    var url = Qt.resolvedUrl(relativePath).toString()
    if (url.indexOf("file://") === 0) return decodeURIComponent(url.slice(7))
    return url
  }

  function configureSettings() {
    if (!Model.validCidr(subnet)) {
      errorText = "Subnet must be valid CIDR (example: 192.168.100.0/24)."
      return false
    }
    if (!Model.validPort(port)) {
      errorText = "Port must be between 1 and 65535."
      return false
    }
    errorText = ""
    settings = Object.assign({}, settings, { subnet: subnet, port: Number(port) })
    if (bar && bar.shell) bar.shell.updateEntryInline("io.github.matthewelgert.lan-mouse", settings)
    return true
  }

  function open() {
    panel.open = true
    refresh()
  }

  function close() {
    panel.open = false
  }

  function toggle() {
    panel.open = !panel.open
    if (panel.open) refresh()
  }

  function refresh() {
    if (!configureSettings()) return
    if (!healthProc.running) {
      healthProc.command = [localPath("scripts/health-check"), "--subnet", subnet, "--port", String(port)]
      healthProc.running = true
    }
  }

  function runAction(commandParts) {
    if (!configureSettings()) return
    errorText = ""
    if (actionProc.running) return
    actionProc.command = commandParts
    actionProc.running = true
  }

  function updateHealth(raw, exitCode) {
    var data = Model.parseKeyValue(raw)
    var next = {
      state: data.state || (exitCode === 0 ? "amber" : "red"),
      message: data.message || "",
      package_installed: data.package_installed || "0",
      config_exists: data.config_exists || "0",
      firewall: data.firewall || "unknown",
      service_installed: data.service_installed || "0",
      service_enabled: data.service_enabled || "0",
      service_active: data.service_active || "0"
    }
    health = next
    healthChangedExternally(next)
  }

  Process {
    id: healthProc
    property int lastExitCode: 1
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateHealth(text, healthProc.lastExitCode)
    }
    onExited: function(exitCode) {
      lastExitCode = exitCode
      if (exitCode !== 0) root.errorText = "Health check failed."
    }
  }

  Process {
    id: actionProc
    property string lastOutput: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: actionProc.lastOutput = text ? text.trim() : ""
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.errorText = actionProc.lastOutput.length > 0 ? actionProc.lastOutput : "Action failed."
      } else {
        root.errorText = ""
      }
      root.refresh()
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: false
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    ColumnLayout {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      Text {
        text: "Lan Mouse"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.bold: true
      }

      Text {
        text: "Status: " + Model.statusLabel(root.health.state)
        color: root.bar ? root.bar.foreground : Color.foreground
      }

      GridLayout {
        columns: 2
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(6)

        Text { text: "Package"; color: root.bar ? root.bar.foreground : Color.foreground }
        Text { text: Model.asBool(root.health.package_installed) ? "Installed" : "Missing"; color: root.bar ? root.bar.foreground : Color.foreground }

        Text { text: "Config"; color: root.bar ? root.bar.foreground : Color.foreground }
        Text { text: Model.asBool(root.health.config_exists) ? "Present" : "Missing"; color: root.bar ? root.bar.foreground : Color.foreground }

        Text { text: "Firewall"; color: root.bar ? root.bar.foreground : Color.foreground }
        Text { text: root.health.firewall || "Unknown"; color: root.bar ? root.bar.foreground : Color.foreground }

        Text { text: "Service"; color: root.bar ? root.bar.foreground : Color.foreground }
        Text { text: Model.serviceSummary(root.health); color: root.bar ? root.bar.foreground : Color.foreground }
      }

      RowLayout {
        Layout.fillWidth: true

        TextField {
          Layout.fillWidth: true
          placeholderText: "Subnet (CIDR)"
          text: root.subnet
          onEditingFinished: root.subnet = text
        }

        TextField {
          Layout.preferredWidth: 110
          placeholderText: "Port"
          text: String(root.port)
          validator: IntValidator { bottom: 1; top: 65535 }
          onEditingFinished: root.port = Number(text)
        }
      }

      RowLayout {
        spacing: Style.space(6)

        Button { text: "Refresh"; onClicked: root.refresh() }
        Button {
          text: "Install & Configure"
          onClicked: root.runAction([root.localPath("scripts/setup-lan-mouse"), "--subnet", root.subnet, "--port", String(root.port)])
        }
        Button {
          text: "Install Service"
          onClicked: root.runAction([root.localPath("scripts/install-user-service")])
        }
      }

      RowLayout {
        spacing: Style.space(6)

        Button { text: "Start"; onClicked: root.runAction(["systemctl", "--user", "start", "lan-mouse.service"]) }
        Button { text: "Stop"; onClicked: root.runAction(["systemctl", "--user", "stop", "lan-mouse.service"]) }
        Button { text: "Restart"; onClicked: root.runAction(["systemctl", "--user", "restart", "lan-mouse.service"]) }
      }

      RowLayout {
        spacing: Style.space(6)

        Button { text: "Launch GUI"; onClicked: Quickshell.execDetached(["lan-mouse"]) }
        Button {
          text: "Open configuration"
          onClicked: Quickshell.execDetached([root.localPath("scripts/open-config")])
        }
        Button {
          text: "Open logs"
          onClicked: Quickshell.execDetached([root.localPath("scripts/open-logs")])
        }
      }

      Text {
        visible: root.health.message && root.health.message.length > 0
        text: root.health.message
        wrapMode: Text.WordWrap
        color: root.bar ? root.bar.foreground : Color.foreground
      }

      Text {
        visible: root.errorText.length > 0
        text: root.errorText
        wrapMode: Text.WordWrap
        color: "#ff6b6b"
      }
    }
  }
}
