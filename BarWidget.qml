import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.matthewelgert.lan-mouse"

  property var health: ({ state: "gray", message: "Loading..." })

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

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function pushHealth(nextHealth) {
    health = nextHealth
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("health" in target) target.health = root.health
    if ("healthChangedExternally" in target) target.healthChangedExternally.connect(root.pushHealth)
  }

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

  Connections {
    target: panelLoader.item
    ignoreUnknownSignals: true
    function onHealthChangedExternally(nextHealth) {
      root.pushHealth(nextHealth)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.statusGlyph(root.health.state)
    tooltipText: "Lan Mouse: " + Model.statusLabel(root.health.state)
    onPressed: root.togglePanel()
  }
}
