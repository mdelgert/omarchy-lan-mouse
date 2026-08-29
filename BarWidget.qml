import QtQuick
import Quickshell.Io
import qs.Ui

// Lan Mouse status icon for the bar, and the host for the control panel.
//
// The icon answers one question at a glance — is the daemon this plugin
// started up? — and the panel behind it answers the rest. Left click opens
// the panel, right click re-runs the health check, middle click launches the
// Lan Mouse GUI for pairing.
//
// Panel.qml owns the health state and every process this plugin runs; this
// widget mirrors what it needs for the icon through guarded reads, the same
// way the built-in clock mirrors its panel's `opened`.
BarWidget {
  id: root
  moduleName: "io.github.mdelgert.lan-mouse"

  // Nerd Font (Material Design) glyphs, matching the bar's existing
  // on/off pairs such as bluetooth 󰂯/󰂲 and microphone 󰍬/󰍭.
  readonly property string iconRunning: "󰍽"
  readonly property string iconStopped: "󰍾"

  // ---- Panel-backed state. Guarded because the bar instantiates the widget
  //      before the Loader has produced an item.
  readonly property string overallTier: panelLoader.item ? String(panelLoader.item.overallTier) : "unknown"
  readonly property bool daemonRunning: panelLoader.item ? panelLoader.item.daemonRunning === true : false
  readonly property string statusLine: panelLoader.item ? String(panelLoader.item.statusLine) : "Checking Lan Mouse..."
  readonly property string tooltipText: panelLoader.item ? String(panelLoader.item.tooltipText) : "Lan Mouse"

  // Only a fault pulls the icon to the urgent color. A stopped daemon is a
  // resting state the user chose, so it stays in the bar's own foreground
  // and says so with the crossed-out glyph instead.
  readonly property bool attention: overallTier === "bad" || overallTier === "warn"

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function startDaemon() { if (panelLoader.item) panelLoader.item.startDaemon() }
  function stopDaemon() { if (panelLoader.item) panelLoader.item.stopDaemon() }
  function launchGui() { if (panelLoader.item) panelLoader.item.launchGui() }
  function openConfig() { if (panelLoader.item) panelLoader.item.openConfig() }
  function openLogs() { if (panelLoader.item) panelLoader.item.openLogs() }
  function runSetup() { if (panelLoader.item) panelLoader.item.runSetup() }

  // ---- Panel lifecycle. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.mdelgert.lan-mouse"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function start(): void { root.startDaemon() }
    function stop(): void { root.stopDaemon() }
    function gui(): void { root.launchGui() }
    function config(): void { root.openConfig() }
    function logs(): void { root.openLogs() }
    function setup(): void { root.runSetup() }
    function status(): string { return root.statusLine }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.daemonRunning ? root.iconRunning : root.iconStopped
    active: root.attention
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else if (b === Qt.MiddleButton) root.launchGui()
      else root.togglePanel()
    }
  }
}
