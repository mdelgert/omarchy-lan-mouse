import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Lan Mouse control panel: four health rows over a block of actions.
//
// The health block is a diagnosis, not a dashboard — each row says what is
// wrong in words and carries the one button that fixes that row, so the user
// never has to work out which action maps to which problem.
//
// Nothing here runs a shell string. Every action is an argv vector aimed at
// a script in ./scripts, and the two settings that reach `ufw` are validated
// in Model.js before the command is built and again inside the script.
//
// BarWidget.qml owns the bar icon and the IPC target, and hands this panel
// the button to anchor against.
Panel {
  id: root
  moduleName: "io.github.mdelgert.lan-mouse"
  ipcTarget: "io.github.mdelgert.lan-mouse"
  // The host widget owns the single IpcHandler this target allows, so it can
  // expose start/stop/setup alongside the panel lifecycle methods.
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings. resolvedSettings reports both the usable value and
  //      whether the stored one was legal, so an invalid entry can be shown
  //      rather than silently replaced by the default.
  readonly property var resolved: Model.resolvedSettings(
    setting("subnet", Model.DEFAULT_SUBNET),
    setting("port", Model.DEFAULT_PORT))
  readonly property string subnet: resolved.subnet
  readonly property int port: resolved.port
  readonly property bool settingsUsable: resolved.subnetValid && resolved.portValid
  readonly property int refreshIntervalSec: Model.normalizedRefreshSec(setting("refreshIntervalSec", Model.DEFAULT_REFRESH_SEC))
  // Opt-out for the login restore. The switch state is recorded either way;
  // this only governs whether the shell acts on it at startup.
  readonly property bool restoreEnabled: setting("restoreDaemonState", true) !== false

  // ---- Health, owned here and mirrored by the bar widget.
  property var health: Model.emptyHealth()
  property bool checking: false
  property string actionStatus: ""
  property string lastError: ""

  readonly property string overallTier: Model.overallTier(health)
  readonly property bool daemonRunning: Model.daemonRunning(health)
  readonly property string statusLine: Model.statusLine(health)
  readonly property string tooltipText: Model.tooltipText(health)
  readonly property bool busy: startProc.running || stopProc.running || restoreProc.running
  readonly property bool canStart: Model.canStart(health) && !busy
  readonly property bool canStop: Model.canStop(health) && !busy

  // ---- Paths. Resolved off this file's own location so the scripts are
  //      found wherever the plugin is checked out.
  readonly property string pluginDir: Model.pathFromUrl(Qt.resolvedUrl("."))
  readonly property bool scriptsAvailable: pluginDir !== ""
  readonly property string configPath: health.paths.config !== ""
    ? health.paths.config
    : (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/lan-mouse/config.toml"

  function script(name) {
    return pluginDir + "/scripts/" + name
  }

  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(contentForeground, 1.4)
  readonly property color okColor: Style.selectedStateColor(contentForeground, Color.accent)

  // Nerd Font (Material Design) glyphs, from the same family the built-in
  // panels draw from.
  readonly property string iconPackage: "󰏖"
  readonly property string iconConfig: "󰈙"
  readonly property string iconFirewall: "󰒃"
  readonly property string iconDaemon: "󰌘"
  readonly property string iconSetup: "󱁤"
  readonly property string iconGui: "󰏌"
  readonly property string iconEdit: "󰷈"
  readonly property string iconLogs: "󰦪"
  readonly property string iconStart: "󰐊"
  readonly property string iconStop: "󰓛"
  readonly property string iconRefresh: "󰑐"

  function tierColor(tier) {
    if (tier === "ok") return root.okColor
    if (tier === "warn" || tier === "bad") return root.urgent
    return root.dim
  }

  // Severity is carried by the glyph as well as the color, so the panel still
  // reads correctly on a theme whose accent and urgent are close together.
  function tierIcon(tier) {
    if (tier === "ok") return "󰄬"
    if (tier === "bad") return "󰅙"
    if (tier === "warn") return "󰀦"
    if (tier === "idle") return "󰄰"
    return "󰘥"
  }

  // ---- Lifecycle ----------------------------------------------------------

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.cursorActive = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Health -------------------------------------------------------------

  function refresh() {
    if (!scriptsAvailable || healthProc.running) return
    root.checking = true
    healthProc.command = [script("health-check"), "--subnet", root.subnet, "--port", String(root.port)]
    healthProc.running = true
  }

  function applyHealth(text) {
    var parsed = Model.parseHealth(text)
    root.health = parsed
    if (!parsed.loaded) root.lastError = "Could not read health status"
    else if (!parsed.settingsValid) root.lastError = parsed.settingsDetail
    else root.lastError = ""
  }

  // ---- Actions ------------------------------------------------------------
  //
  // Two shapes only. In-process work goes through a Process with an argv
  // vector; anything that has to be watched by the user (a sudo prompt, a
  // log tail) goes to a terminal. Neither path ever concatenates a value
  // into a command string.

  function startDaemon() {
    if (!scriptsAvailable || root.busy) return
    root.actionStatus = "Starting daemon..."
    root.lastError = ""
    startProc.command = [script("start-daemon")]
    startProc.running = true
  }

  function stopDaemon() {
    if (!scriptsAvailable || root.busy) return
    root.actionStatus = "Stopping daemon..."
    root.lastError = ""
    stopProc.command = [script("stop-daemon")]
    stopProc.running = true
  }

  function toggleDaemon() {
    if (root.canStop) root.stopDaemon()
    else if (root.canStart) root.startDaemon()
  }

  // ---- Login restore ------------------------------------------------------
  //
  // The daemon is a child of the graphical session, so it dies with it, and
  // the PID file it is tracked by lives in the runtime directory the session
  // takes with it. Neither can carry "the user left this switched on" across
  // a reboot; scripts/lib.sh records that separately, and this is what acts
  // on it. The script decides whether anything should happen — the panel
  // only decides when to ask.

  property int restoreAttempts: 0
  // A start at login can lose a race with the portal or the Wayland socket
  // and fail for a reason that is gone seconds later, so a failure is worth
  // retrying. A limit, because a failure that is not transient (a port held
  // by something else) must not turn into a loop.
  readonly property int maxRestoreAttempts: 3

  function restoreDaemonState() {
    if (!scriptsAvailable || !root.restoreEnabled) return
    if (root.busy) return
    if (root.restoreAttempts >= root.maxRestoreAttempts) return
    root.restoreAttempts += 1
    restoreProc.command = [script("restore-daemon")]
    restoreProc.running = true
  }

  // Quoted once for the launcher, which rejoins its arguments with "$*" and
  // hands the result to a single `bash -c`. execArgv passes the argv through
  // without a second round of word splitting, so this is exactly one level
  // of quoting rather than two.
  function launchInTerminal(argv) {
    var quoted = []
    for (var i = 0; i < argv.length; i++) quoted.push(Util.shellQuote(argv[i]))
    Util.execArgv(["omarchy-launch-floating-terminal-with-presentation", quoted.join(" ")])
  }

  function runSetup() {
    if (!scriptsAvailable) return
    // Refused rather than run against the fallback: opening the firewall for
    // a subnet the user did not ask for is worse than doing nothing.
    if (!root.settingsUsable) {
      root.lastError = "Fix the subnet and port settings before running setup"
      return
    }
    launchInTerminal([script("setup-repair"), root.subnet, String(root.port)])
    root.close()
  }

  function openLogs() {
    if (!scriptsAvailable) return
    launchInTerminal([script("open-logs")])
    root.close()
  }

  function launchGui() {
    Util.execArgv(["lan-mouse"])
    root.close()
  }

  function openConfig() {
    Util.execArgv(["omarchy-launch-editor", root.configPath])
    root.close()
  }

  // ---- Keyboard cursor ----------------------------------------------------
  //
  // The cursor walks the action buttons only. Health rows are a read-out
  // whose inline buttons duplicate actions already in the grid, so putting
  // them in the tab order would mean two stops for one thing.

  property bool cursorActive: false
  property int cursorIndex: 0

  // Grid order, two columns wide, with Refresh spanning the last row.
  readonly property int actionCount: 7

  function actionEnabled(index) {
    if (!scriptsAvailable) return false
    if (index === 0) return root.canStart
    if (index === 1) return root.canStop
    return true
  }

  function invokeAction(index) {
    if (!actionEnabled(index)) return
    if (index === 0) root.startDaemon()
    else if (index === 1) root.stopDaemon()
    else if (index === 2) root.launchGui()
    else if (index === 3) root.openConfig()
    else if (index === 4) root.openLogs()
    else if (index === 5) root.runSetup()
    else if (index === 6) root.refresh()
  }

  function setCursor(index) {
    root.cursorActive = true
    root.cursorIndex = Math.max(0, Math.min(root.actionCount - 1, index))
  }

  function moveCursor(dx, dy) {
    // Two columns, so a vertical step is a step of two.
    var next = root.cursorIndex + dx + dy * 2
    root.cursorIndex = Math.max(0, Math.min(root.actionCount - 1, next))
  }

  function activateCursor() {
    root.invokeAction(root.cursorIndex)
  }

  onOpenedChanged: {
    if (!root.opened) root.cursorActive = false
  }

  Component.onCompleted: {
    root.refresh()
    // Delayed rather than immediate: the shell is up well before the portal
    // the daemon needs, and the first attempt is the one most likely to be
    // wasted otherwise.
    restoreTimer.start()
  }

  // ---- Processes ----------------------------------------------------------

  Process {
    id: healthProc
    running: false
    command: []
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    stderr: StdioCollector { id: healthErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.checking = false
      if (exitCode === 0) {
        root.applyHealth(String(healthOut.text || ""))
      } else {
        root.health = Model.emptyHealth()
        root.lastError = String(healthErr.text || "").trim() || "Health check failed"
      }
    }
  }

  Process {
    id: startProc
    running: false
    command: []
    stdout: StdioCollector { id: startOut; waitForEnd: true }
    stderr: StdioCollector { id: startErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(startOut.text || "").trim()
      var err = String(startErr.text || "").trim()
      if (exitCode === 0) {
        root.actionStatus = out || "Daemon started"
        root.lastError = ""
      } else {
        root.actionStatus = ""
        // The script tails the daemon log on failure; the first line is the
        // reason, the rest is context better read in Open logs.
        root.lastError = (err.split("\n")[0] || "Could not start the daemon").replace(/^start-daemon:\s*/, "")
      }
      actionStatusTimer.restart()
      root.refresh()
    }
  }

  Process {
    id: stopProc
    running: false
    command: []
    stdout: StdioCollector { id: stopOut; waitForEnd: true }
    stderr: StdioCollector { id: stopErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(stopOut.text || "").trim()
      var err = String(stopErr.text || "").trim()
      if (exitCode === 0) {
        root.actionStatus = out || "Daemon stopped"
        root.lastError = ""
      } else {
        root.actionStatus = ""
        root.lastError = (err.split("\n")[0] || "Could not stop the daemon").replace(/^stop-daemon:\s*/, "")
      }
      actionStatusTimer.restart()
      root.refresh()
    }
  }

  Process {
    id: restoreProc
    running: false
    command: []
    stdout: StdioCollector { id: restoreOut; waitForEnd: true }
    stderr: StdioCollector { id: restoreErr; waitForEnd: true }
    onExited: function(exitCode) {
      // 10 is the script's "nothing to do" — switched off, already running,
      // not installed. That is the common case at login and says nothing the
      // health rows do not already say, so it stays silent.
      if (exitCode === 0) {
        root.actionStatus = String(restoreOut.text || "").trim() || "Restored the daemon"
        root.lastError = ""
        actionStatusTimer.restart()
      } else if (exitCode === 1) {
        if (root.restoreAttempts < root.maxRestoreAttempts) {
          restoreTimer.interval = 15000
          restoreTimer.restart()
        } else {
          var err = String(restoreErr.text || "").trim()
          root.lastError = (err.split("\n")[0] || "Could not restore the daemon")
            .replace(/^start-daemon:\s*/, "")
        }
      }
      root.refresh()
    }
  }

  Timer {
    id: restoreTimer
    interval: 2500
    repeat: false
    // Every attempt after the first re-reads health first: if the daemon came
    // up in the meantime, or the switch was turned off while the retry was
    // pending, there is nothing left to restore.
    onTriggered: {
      if (root.restoreAttempts > 0 && !Model.restorePending(root.health)) return
      root.restoreDaemonState()
    }
  }

  // Action results are transient; health is what the panel settles back to.
  Timer {
    id: actionStatusTimer
    interval: 6000
    onTriggered: root.actionStatus = ""
  }

  // Polls faster while the panel is open so Start and Stop settle visibly,
  // and at the configured interval otherwise to keep the bar icon honest.
  Timer {
    running: true
    repeat: true
    interval: 1000 * (root.opened
      ? Math.min(Model.OPEN_REFRESH_SEC, root.refreshIntervalSec)
      : root.refreshIntervalSec)
    onTriggered: root.refresh()
  }

  // ---- Rows ---------------------------------------------------------------

  component HealthRow: CursorSurface {
    id: row

    property string rowIcon: ""
    property string label: ""
    property string tier: "unknown"
    property string detail: ""
    property string actionIcon: ""
    property string actionTooltip: ""
    property bool actionEnabled: true
    property bool actionVisible: true

    signal actionTriggered()

    foreground: root.contentForeground
    implicitHeight: Math.max(Style.space(38), rowText.implicitHeight + Style.space(14))

    Text {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: row.rowIcon
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rowText
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowStatus.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: row.label
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: row.detail !== ""
        text: row.detail
        color: root.dim
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // Severity mark, then the row's own fix. Both sit at the trailing edge so
    // the four rows scan as a column of verdicts.
    Text {
      id: rowStatus
      anchors.right: rowAction.visible ? rowAction.left : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.tierIcon(row.tier)
      color: root.tierColor(row.tier)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.icon
    }

    PanelActionButton {
      id: rowAction
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: row.actionVisible && row.actionIcon !== ""
      enabled: row.actionEnabled
      iconText: row.actionIcon
      tooltipText: row.actionTooltip
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      onClicked: row.actionTriggered()
    }
  }

  component ActionButton: Button {
    property int actionIndex: -1

    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    leftAlign: true
    bordered: true
    enabled: root.actionEnabled(actionIndex)
    opacity: enabled ? 1.0 : 0.45
    hasCursor: root.cursorActive && root.cursorIndex === actionIndex
    onHovered: function(on) { if (on && enabled) root.setCursor(actionIndex) }
    onClicked: root.invokeAction(actionIndex)
  }

  // ---- Panel --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "s") root.startDaemon()
        else if (key === "x") root.stopDaemon()
        else if (key === "g") root.launchGui()
        else if (key === "c") root.openConfig()
        else if (key === "l") root.openLogs()
        else if (key === "u") root.runSetup()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Hero: what the daemon is doing, and the switch that changes it.
          PanelHero {
            id: hero
            width: parent.width
            title: "Lan Mouse"
            meta: root.statusLine
            detail: Model.versionLabel(root.health)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconOpacity: root.daemonRunning ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                text: root.daemonRunning ? "󰍽" : "󰍾"
                color: root.tierColor(root.overallTier)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: daemonSwitch
                checked: root.daemonRunning
                busy: root.busy
                interactive: root.canStart || root.canStop
                foreground: hero.foreground
                onToggled: root.toggleDaemon()

                PanelToolTip {
                  visible: daemonSwitch.containsMouse
                  text: root.canStop
                    ? "Stop the daemon"
                    : (root.canStart ? "Start the daemon" : root.statusLine)
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          // Transient result of the last action, or the reason it failed.
          Text {
            width: parent.width
            visible: root.actionStatus !== "" || root.lastError !== ""
            text: root.lastError !== "" ? root.lastError : root.actionStatus
            color: root.lastError !== "" ? root.urgent : root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Health: four independent verdicts, each with its own fix.
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: healthHeader.implicitHeight

              PanelSectionHeader {
                id: healthHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "HEALTH"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.checking
                text: "CHECKING"
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            HealthRow {
              width: parent.width
              rowIcon: root.iconPackage
              label: "Package"
              tier: Model.tierFor(root.health, "package")
              detail: root.health.package.detail
              actionIcon: root.iconSetup
              actionTooltip: "Install lan-mouse"
              actionVisible: Model.tierFor(root.health, "package") !== "ok"
              onActionTriggered: root.runSetup()
            }

            HealthRow {
              width: parent.width
              rowIcon: root.iconConfig
              label: "Configuration"
              tier: Model.tierFor(root.health, "config")
              detail: root.health.config.detail
              actionIcon: root.iconEdit
              actionTooltip: "Open config.toml"
              onActionTriggered: root.openConfig()
            }

            HealthRow {
              width: parent.width
              rowIcon: root.iconFirewall
              label: "Firewall"
              tier: Model.tierFor(root.health, "firewall")
              detail: root.health.firewall.detail
              actionIcon: root.iconSetup
              actionTooltip: "Add the UFW rule"
              actionEnabled: root.settingsUsable
              actionVisible: Model.tierFor(root.health, "firewall") !== "ok"
              onActionTriggered: root.runSetup()
            }

            HealthRow {
              width: parent.width
              rowIcon: root.iconDaemon
              label: "Daemon"
              tier: Model.tierFor(root.health, "daemon")
              detail: root.health.daemon.detail
              actionIcon: root.daemonRunning ? root.iconStop : root.iconStart
              actionTooltip: root.daemonRunning ? "Stop the daemon" : "Start the daemon"
              actionEnabled: root.canStart || root.canStop
              onActionTriggered: root.toggleDaemon()
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Actions.
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ACTIONS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Grid {
              id: actionGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              readonly property real cellWidth: Math.floor((width - columnSpacing) / 2)

              ActionButton {
                actionIndex: 0
                width: actionGrid.cellWidth
                iconText: root.iconStart
                text: "Start daemon"
                tooltipText: "Run lan-mouse daemon in this session (S)"
              }

              ActionButton {
                actionIndex: 1
                width: actionGrid.cellWidth
                iconText: root.iconStop
                text: "Stop daemon"
                tooltipText: "Stop only the daemon this plugin started (X)"
              }

              ActionButton {
                actionIndex: 2
                width: actionGrid.cellWidth
                iconText: root.iconGui
                text: "Launch GUI"
                tooltipText: "Open Lan Mouse to pair and authorize devices (G)"
              }

              ActionButton {
                actionIndex: 3
                width: actionGrid.cellWidth
                iconText: root.iconEdit
                text: "Open config"
                tooltipText: root.configPath + " (C)"
              }

              ActionButton {
                actionIndex: 4
                width: actionGrid.cellWidth
                iconText: root.iconLogs
                text: "Open logs"
                tooltipText: "Follow the daemon log (L)"
              }

              ActionButton {
                actionIndex: 5
                width: actionGrid.cellWidth
                iconText: root.iconSetup
                text: "Setup / Repair"
                tooltipText: "Authenticate, then install lan-mouse and add the UFW rule (U)"
              }
            }

            ActionButton {
              actionIndex: 6
              width: parent.width
              iconText: root.iconRefresh
              text: "Refresh"
              tooltipText: "Re-run the health check (R)"
            }
          }

          // The exact rule Setup / Repair would add, so the privileged action
          // is legible before it is triggered rather than only afterwards.
          Text {
            width: parent.width
            text: root.settingsUsable
              ? Model.ufwRuleText(root.subnet, root.port)
              : "Invalid subnet or port setting — Setup / Repair is disabled"
            color: root.settingsUsable ? root.dim : root.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
