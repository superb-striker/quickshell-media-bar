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
  property bool playing: false
  property real lastClickTime: 0
  property string helper: "/home/" + (Quickshell.env("USER") || "superb-striker") + "/.config/omarchy/bar/modules/media-backend.py"
  implicitWidth: hasPlayer ? (bar ? bar.barSize : 28) : 0
  implicitHeight: bar ? bar.barSize : 28
  visible: hasPlayer
  // Poll the same priority-aware state the rest of the widgets use, instead
  // of a raw `playerctl status`, so this button always reflects/controls
  // whichever player is actually selected (local player prioritized over a
  // browser tab), not just whatever playerctl considers "active".
  Process {
    id: check
    command: ["python3", root.helper, "state"]
    stdout: SplitParser {
      onRead: data => {
        try {
          const state = JSON.parse(data)
          root.hasPlayer = !!state.available
          // Ignore state readings for a short window right after a click:
          // the backend action may not have taken effect yet, so trust the
          // optimistic flip instead of snapping back to the stale value.
          if (Date.now() - root.lastClickTime > 250) {
            root.playing = !!state.playing
          }
        } catch (e) {
        }
      }
    }
  }
  Timer { 
      interval: 350; 
      running: true; 
      repeat: true; 
      triggeredOnStart: true; 
      onTriggered: check.running = true 
  }
  Process { 
      id: action; 
      command: ["python3", root.helper, "command", "play-pause"] 
  }
  Text {
    anchors.centerIn: parent
    text: root.playing ? "󰏤" : "󰐊"
    color: bar ? bar.foreground : "white"
    font.family: bar ? bar.fontFamily : undefined
    font.pixelSize: root.fontPx
  }
  MouseArea {
    anchors.fill: parent
    enabled: root.hasPlayer
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      root.playing = !root.playing
      root.lastClickTime = Date.now()
      action.running = true
    }
  }
}
