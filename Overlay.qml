import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Find any file on the disk by name as you type. bin/find-files-search does
// the looking (plocate's index, plus fd for files newer than the index); this
// only shows what it returns.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "tqdesign.find-files"
  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string home: Quickshell.env("HOME")

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  readonly property var orders: ["relevance", "name", "modified", "size"]
  property int orderIndex: 0
  readonly property string order: orders[orderIndex]

  // The search runs one at a time; a query typed meanwhile runs next.
  property bool stale: false
  property bool waiting: false
  property bool tooShort: false
  property int total: 0
  property bool capped: false
  property double indexedAt: 0
  property string notice: ""

  // Shares the [menu] surface tokens, so themes that style the menu style this.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Style.font.bodySmall + Style.spacing.md
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Style.font.subtitle + Style.spacing.xl * 2
  property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.notice = ""
    root.orderIndex = 0
    root.clearResults()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    debounce.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function clearResults() {
    resultModel.clear()
    root.selectedIndex = 0
    root.total = 0
    root.capped = false
    root.tooShort = false
    root.waiting = false
  }

  function setFilter(text) {
    root.filterText = text
    root.notice = ""
    if (text.trim() === "") {
      debounce.stop()
      root.clearResults()
      return
    }
    root.waiting = true
    debounce.restart()
  }

  function runSearch() {
    if (!root.opened || root.filterText.trim() === "") return
    if (searchProc.running) {
      root.stale = true
      return
    }
    root.stale = false
    searchProc.command = [root.pluginDir + "/bin/find-files-search", root.order, root.filterText]
    searchProc.running = true
  }

  function loadResults(text) {
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    // An answer to an older query; the newer one is already queued.
    if (!data || data.query !== root.filterText || data.order !== root.order) return

    resultModel.clear()
    for (var i = 0; i < data.rows.length; i++) {
      var row = data.rows[i]
      var slash = row.p.lastIndexOf("/")
      resultModel.append({
        path: row.p,
        name: row.p.slice(slash + 1) || "/",
        folder: root.shortPath(row.p.slice(0, slash) || "/"),
        isDir: row.d,
        sizeText: row.d ? "" : root.formatSize(row.s),
        dateText: root.formatDate(row.m)
      })
    }
    root.total = data.total
    root.capped = data.capped
    root.tooShort = data.short === true
    root.indexedAt = data.indexed
    root.waiting = false
    root.selectedIndex = 0
    resultList.positionViewAtBeginning()
  }

  function shortPath(path) {
    if (path === root.home) return "~"
    return path.indexOf(root.home + "/") === 0 ? "~" + path.slice(root.home.length) : path
  }

  function formatSize(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var value = bytes
    var unit = 0
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024
      unit += 1
    }
    return (unit === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[unit]
  }

  function formatDate(seconds) {
    var date = new Date(seconds * 1000)
    var now = new Date()
    if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "h:mm AP")
    if (date.getFullYear() === now.getFullYear()) return Qt.formatDate(date, "MMM d")
    return Qt.formatDate(date, "MMM d, yyyy")
  }

  function indexAge() {
    if (!root.indexedAt) return ""
    var minutes = Math.max(0, Math.round((Date.now() / 1000 - root.indexedAt) / 60))
    if (minutes < 90) return "index " + minutes + " min old"
    var hours = Math.round(minutes / 60)
    return hours < 48 ? "index " + hours + " h old" : "index " + Math.round(hours / 24) + " days old"
  }

  function statusText() {
    if (root.notice !== "") return root.notice
    if (root.filterText.trim() === "") return "Type part of a file name. Spaces narrow it down; * and ? are wildcards; add a / to match folders in the path."
    if (root.tooShort) return "Keep typing…"
    if (root.waiting && resultModel.count === 0) return "Searching…"
    var count = root.capped ? "Over " + root.total.toLocaleString(Qt.locale(), "f", 0)
      : root.total.toLocaleString(Qt.locale(), "f", 0)
    var text = count + (root.total === 1 ? " match" : " matches")
    if (root.total > resultModel.count) text += ", showing " + resultModel.count
    text += " · by " + root.order
    var age = root.indexAge()
    if (age !== "") text += " · " + age
    return text
  }

  function select(delta) {
    if (resultModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(resultModel.count - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function pageRows() {
    return Math.max(1, Math.floor(resultList.height / root.rowHeight) - 1)
  }

  function selectedPath() {
    if (root.selectedIndex < 0 || root.selectedIndex >= resultModel.count) return ""
    return resultModel.get(root.selectedIndex).path
  }

  function openSelected() {
    var path = root.selectedPath()
    if (path === "") return
    root.dismiss()
    Quickshell.execDetached(["xdg-open", path])
  }

  function revealSelected() {
    var path = root.selectedPath()
    if (path === "") return
    root.dismiss()
    Quickshell.execDetached([root.pluginDir + "/bin/find-files-reveal", path])
  }

  function copySelected() {
    var path = root.selectedPath()
    if (path === "") return
    Quickshell.execDetached(["wl-copy", "--", path])
    root.notice = "Copied " + root.shortPath(path)
  }

  function cycleOrder() {
    root.orderIndex = (root.orderIndex + 1) % root.orders.length
    root.notice = ""
    if (root.filterText.trim() !== "") {
      root.waiting = true
      root.runSearch()
    }
  }

  ListModel { id: resultModel }

  Timer {
    id: debounce
    interval: 40
    onTriggered: root.runSearch()
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadResults(text)
    }
    onExited: if (root.stale) root.runSearch()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "tqdesign-find-files"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          event.accepted = true
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (ctrl) root.revealSelected()
            else root.openSelected()
          } else if (ctrl && event.key === Qt.Key_C) {
            root.copySelected()
          } else if (ctrl && event.key === Qt.Key_S) {
            root.cycleOrder()
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-root.pageRows())
          } else if (event.key === Qt.Key_PageDown) {
            root.select(root.pageRows())
          } else if (ctrl && event.key === Qt.Key_Home) {
            root.select(-resultModel.count)
          } else if (ctrl && event.key === Qt.Key_End) {
            root.select(resultModel.count)
          } else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
          } else {
            event.accepted = false
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Find files…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          ListView {
            id: resultList
            anchors.fill: parent
            model: resultModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: resultRow
              required property int index
              required property string path
              required property string name
              required property string folder
              required property bool isDir
              required property string sizeText
              required property string dateText

              readonly property bool hasCursor: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.lg
                anchors.rightMargin: Style.spacing.lg
                spacing: Style.spacing.xl

                readonly property int sizeWidth: Style.space(76)
                readonly property int dateWidth: Style.space(104)
                readonly property int iconWidth: Style.font.title + Style.spacing.sm
                readonly property int textWidth: width - iconWidth - sizeWidth - dateWidth - spacing * 4

                Text {
                  width: parent.iconWidth
                  anchors.verticalCenter: parent.verticalCenter
                  text: resultRow.isDir ? "󰉋" : "󰈔"
                  color: resultRow.hasCursor ? root.selectedText : root.foreground
                  opacity: resultRow.isDir ? 0.9 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }
                Text {
                  id: nameText
                  textFormat: Text.PlainText
                  width: Math.min(implicitWidth, parent.textWidth * 0.6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: resultRow.name
                  color: resultRow.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideMiddle
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.textWidth - nameText.width
                  anchors.verticalCenter: parent.verticalCenter
                  text: resultRow.folder
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                }
                Text {
                  width: parent.sizeWidth
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: resultRow.sizeText
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: parent.dateWidth
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  text: resultRow.dateText
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectedIndex = resultRow.index
                onDoubleClicked: {
                  root.selectedIndex = resultRow.index
                  root.openSelected()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: resultModel.count === 0 && root.filterText.trim() !== "" && !root.waiting && !root.tooShort
            text: "No files match “" + root.filterText + "”"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            id: keyHints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter open · Ctrl+Enter show in folder · Ctrl+C copy path · Ctrl+S sort"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: keyHints.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText()
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
