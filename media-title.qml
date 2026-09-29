import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
Item {
  id: root
  property var bar
  property string moduleName
  property var settings
  property int fixedWidth: (settings && settings.width) ? settings.width : 180
  property real speedPxPerSec: (settings && settings.speed) ? settings.speed : 40
  property int fontPx: (settings && settings.fontSize) ? settings.fontSize : 12
  property int popupWidth: 300
  property int popupMargin: 8
  // How far the module's right edge sits from the bar's true right edge
  // (the width taken up by whatever sits after it - tray icons, clock,
  // etc). Tweak this until the popup's right edge lines up with the
  // edge of your bar.
  property int rightEdgeOffset: 230
  property int moduleGap: 0
  property string helper: (Quickshell.env("HOME") || "/home/" + (Quickshell.env("USER") || "superb-striker")) + "/.config/omarchy/bar/modules/media-backend.py"
  property bool hasPlayer: false
  property bool popupOpen: false
  property bool queueExpanded: true
  property var media: ({available: false, playing: false, title: "", artist: "", album: "", position: 0, duration: 0, playlistPos: -1, art: "", queue: [], hasQueue: false, source: "", isLocal: false, sources: []})
  // The popup opens for any active source. When the current source is a
  // local/native player (mpv, vlc, kew, ...) it shows the full player card
  // (art, title, seek bar, queue). When it's a web/browser source it shows
  // a stripped-down card instead - just transport controls and a way to
  // switch back to a local player - since title/art/seeking generally
  // don't work well against a browser tab.
  property bool popupEligible: root.hasPlayer
  implicitHeight: bar ? bar.barSize : 28
  implicitWidth: hasPlayer ? fixedWidth : 0
  visible: hasPlayer
  clip: true
  onPopupEligibleChanged: if (!popupEligible && popupOpen) popupOpen = false
  Process {
    id: mediaDaemon
    command: ["python3", root.helper, "daemon"]
    stdinEnabled: true
    running: root.helper.length > 0
    stdout: SplitParser {
      onRead: data => {
        try {
          const state = JSON.parse(data)
          root.media = state
          root.hasPlayer = !!state.available
        } catch (e) {
        }
      }
    }
    onExited: {
      root.hasPlayer = false
      restartTimer.start()
    }
  }
  Timer {
    id: restartTimer
    interval: 1000
    repeat: false
    onTriggered: if (!mediaDaemon.running) mediaDaemon.running = true
  }
  Text {
    id: titleText
    anchors.fill: parent
    text: root.media.title + (root.media.artist ? " - " + root.media.artist : "")
    color: bar ? bar.foreground : "white"
    font.family: bar ? bar.fontFamily : undefined
    font.pixelSize: root.fontPx
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
    opacity: root.popupOpen ? 0.7 : 1
  }
  MouseArea {
    anchors.fill: parent
    enabled: root.popupEligible
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.popupOpen = !root.popupOpen
  }
  PopupWindow {
    id: popup
    // Anchor to the window's own content item (a real Item spanning the
    // full window, always available via the standard Qt Window attached
    // property) rather than this small module or the `bar` object, whose
    // exact type we can't rely on. This keeps the popup's right edge flush
    // with the true screen edge at any resolution or display scale,
    // without any hardcoded pixel offset.
    anchor.item: root.Window.contentItem
    anchor.edges: Edges.Top | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.top: (bar ? bar.barSize : 28) + root.popupMargin
    anchor.adjustment: PopupAdjustment.All
    implicitWidth: root.popupWidth
    implicitHeight: contentColumn.implicitHeight + 32
    visible: root.popupOpen && root.popupEligible
    grabFocus: true
    color: "transparent"
    onVisibleChanged: {
      if (!visible) {
        root.popupOpen = false
      } else {
        popup.updateAnchor()
        popupFocusItem.forceActiveFocus()
      }
    }
    Behavior on implicitHeight { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Rectangle {
      id: popupFocusItem
      anchors.fill: parent
      radius: 18
      color: bar && bar.background ? bar.background : "#161616"
      border.width: 1
      border.color: Qt.alpha(bar ? bar.foreground : "white", 0.12)
      focus: true
      Keys.onEscapePressed: root.popupOpen = false
      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        spacing: 12
        Row {
          id: sourceRow
          width: parent.width
          height: visible ? 26 : 0
          spacing: 6
          visible: root.media.sources && root.media.sources.length > 1
          Repeater {
            model: root.media.sources
            delegate: Rectangle {
              height: 22
              width: sourceLabel.implicitWidth + 16
              radius: 11
              color: modelData.selected ? (bar ? bar.foreground : "white") : Qt.alpha(bar ? bar.foreground : "white", 0.08)
              Text {
                id: sourceLabel
                anchors.centerIn: parent
                text: modelData.label
                color: modelData.selected ? (bar && bar.background ? bar.background : "#161616") : Qt.alpha(bar ? bar.foreground : "white", 0.75)
                font.family: bar ? bar.fontFamily : undefined
                font.pixelSize: 10
                font.bold: modelData.selected
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.send("select-source", [modelData.name])
              }
            }
          }
        }
        Row {
          width: parent.width
          height: visible ? 84 : 0
          spacing: 12
          visible: root.media.isLocal
          Rectangle {
            width: 84
            height: 84
            radius: 12
            color: Qt.alpha(bar ? bar.foreground : "white", 0.06)
            Image {
              id: coverImage
              anchors.fill: parent
              anchors.margins: 1
              source: root.media.art || ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              visible: status === Image.Ready
              layer.enabled: true
            }
            Text {
              anchors.centerIn: parent
              text: "󰝚"
              color: Qt.alpha(bar ? bar.foreground : "white", 0.3)
              font.pixelSize: 30
              visible: coverImage.status !== Image.Ready
            }
          }
          Column {
            width: parent.width - 96
            height: parent.height
            spacing: 4
            Item { width: 1; height: 2 }
            Text {
              width: parent.width
              text: root.media.title
              color: bar ? bar.foreground : "white"
              font.family: bar ? bar.fontFamily : undefined
              font.pixelSize: 15
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: root.media.artist || "Unknown artist"
              color: Qt.alpha(bar ? bar.foreground : "white", 0.6)
              font.family: bar ? bar.fontFamily : undefined
              font.pixelSize: 12
              elide: Text.ElideRight
            }
            Item { width: 1; height: 6 }
            Text {
              width: parent.width
              text: formatTime(root.media.position) + " / " + formatTime(root.media.duration)
              color: Qt.alpha(bar ? bar.foreground : "white", 0.45)
              font.family: bar ? bar.fontFamily : undefined
              font.pixelSize: 10
            }
          }
        }
        Rectangle {
          width: parent.width
          height: visible ? 3 : 0
          radius: 1.5
          visible: root.media.isLocal
          color: Qt.alpha(bar ? bar.foreground : "white", 0.12)
          Rectangle {
            width: parent.width * (root.media.duration > 0 ? Math.min(1, root.media.position / root.media.duration) : 0)
            height: parent.height
            radius: 1.5
            color: bar ? bar.foreground : "white"
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => root.seek(mouse.x / width)
          }
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          height: 44
          spacing: 16
          MediaButton { width: 38; height: 38; glyph: "󰒮"; onClicked: root.send("previous") }
          MediaButton {
            width: 44
            height: 44
            glyph: root.media.playing ? "󰏤" : "󰐊"
            filled: true
            onClicked: root.send("play-pause")
          }
          MediaButton { width: 38; height: 38; glyph: "󰒭"; onClicked: root.send("next") }
        }
        Row {
          width: parent.width
          height: 20
          visible: root.media.hasQueue
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.queueExpanded = !root.queueExpanded
            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Text {
                text: "UP NEXT"
                color: Qt.alpha(bar ? bar.foreground : "white", 0.4)
                font.family: bar ? bar.fontFamily : undefined
                font.pixelSize: 10
                font.bold: true
              }
              Text {
                text: "(" + root.media.queue.length + ")"
                color: Qt.alpha(bar ? bar.foreground : "white", 0.3)
                font.family: bar ? bar.fontFamily : undefined
                font.pixelSize: 10
              }
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.queueExpanded ? "󰅃" : "󰅀"
              color: Qt.alpha(bar ? bar.foreground : "white", 0.4)
              font.pixelSize: 12
            }
          }
        }
        ListView {
          id: queueView
          width: parent.width
          height: (root.media.hasQueue && root.queueExpanded) ? Math.min(180, root.media.queue.length * 40) : 0
          clip: true
          spacing: 2
          visible: height > 0
          model: root.media.queue
          Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          delegate: Rectangle {
            width: queueView.width
            height: 38
            radius: 8
            color: modelData.current ? Qt.alpha(bar ? bar.foreground : "white", 0.10) : (rowArea.containsMouse ? Qt.alpha(bar ? bar.foreground : "white", 0.05) : "transparent")
            Rectangle {
              visible: modelData.current
              width: 3
              height: parent.height - 12
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: 4
              radius: 1.5
              color: bar ? bar.foreground : "white"
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: modelData.current ? 16 : 10
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.title
              color: modelData.current ? (bar ? bar.foreground : "white") : Qt.alpha(bar ? bar.foreground : "white", 0.65)
              font.family: bar ? bar.fontFamily : undefined
              font.pixelSize: 12
              font.bold: modelData.current
              elide: Text.ElideRight
            }
            MouseArea {
              id: rowArea
              anchors.fill: parent
              enabled: !modelData.current
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playIndex(modelData.index)
            }
          }
        }
      }
    }
  }
  component MediaButton: Rectangle {
    property string glyph: ""
    property bool filled: false
    signal clicked()
    radius: width / 2
    color: filled ? (bar ? bar.foreground : "white") : (buttonArea.containsMouse ? Qt.alpha(bar ? bar.foreground : "white", 0.10) : "transparent")
    Text {
      anchors.centerIn: parent
      text: parent.glyph
      color: parent.filled ? (bar && bar.background ? bar.background : "#161616") : (bar ? bar.foreground : "white")
      font.family: bar ? bar.fontFamily : undefined
      font.pixelSize: parent.width > 40 ? 20 : 16
    }
    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }
  function send(action, args) {
    if (!mediaDaemon.running) return
    mediaDaemon.write(JSON.stringify({action: action, args: args || []}) + "\n")
  }
  function playIndex(index) {
    send("play-index", [index])
  }
  function seek(fraction) {
    if (root.media.duration > 0) send("seek", [fraction * root.media.duration])
  }
  function formatTime(value) {
    if (!isFinite(value) || value < 0) return "0:00"
    const total = Math.floor(value)
    const seconds = total % 60
    const minutes = Math.floor(total / 60) % 60
    const hours = Math.floor(total / 3600)
    const sec = seconds < 10 ? "0" + seconds : seconds
    return hours > 0 ? hours + ":" + (minutes < 10 ? "0" + minutes : minutes) + ":" + sec : minutes + ":" + sec
  }
}
