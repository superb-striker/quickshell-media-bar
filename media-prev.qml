import QtQuick
import Quickshell
import Quickshell.Io
Item {
  id: root
  property var bar
  property string moduleName
  property var settings
  property int fontPx: (settings && settings.fontSize) ? settings.fontSize : 12
  property bool hasPlayer: false
  property string helper: "/home/" + (Quickshell.env("USER") || "superb-striker") + "/.config/omarchy/bar/modules/media-backend.py"
  implicitWidth: hasPlayer ? (bar ? bar.barSize : 28) : 0
  implicitHeight: bar ? bar.barSize : 28
  visible: hasPlayer
  Process {
    id: check
    command: ["python3", root.helper, "state"]
    stdout: SplitParser {
      onRead: data => {
        try {
          const state = JSON.parse(data)
          root.hasPlayer = !!state.available
        } catch (e) {
        }
      }
    }
  }
  Timer { interval: 800; running: true; repeat: true; triggeredOnStart: true; onTriggered: check.running = true }
  Process { id: action; command: ["python3", root.helper, "command", "previous"] }
  Text { anchors.centerIn: parent; text: "󰒮"; color: bar ? bar.foreground : "white"; font.family: bar ? bar.fontFamily : undefined; font.pixelSize: root.fontPx }
  MouseArea { anchors.fill: parent; enabled: root.hasPlayer; cursorShape: Qt.PointingHandCursor; onClicked: action.running = true }
}
