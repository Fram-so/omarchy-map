import QtQuick
import Quickshell.Widgets

// One agent's camp on the map: round avatar, name plate, and for the freshest
// voices a quote bubble with their last message. The item's (0,0) is the
// avatar's center, so the Service can place camps by map coordinate alone.
Item {
  id: camp

  property var agent: ({})
  property real size: 56
  property bool fresh: false
  property bool showBubble: false
  property bool bubbleOnLeft: false
  // Staggers neighbouring bubbles vertically so two fresh voices camping
  // side by side don't overlap each other's quotes.
  property int bubbleRank: 0
  property string ago: ""
  property bool interactive: false
  property bool hovered: pointer.containsMouse

  signal activated()
  signal hoverChanged(bool inside)

  width: 1
  height: 1

  // ── glow for fresh voices ─────────────────────────────────────────────
  Rectangle {
    id: glow
    visible: camp.fresh
    width: camp.size * 1.7
    height: width
    radius: width / 2
    x: -width / 2
    y: -height / 2
    color: "#EB7100"
    opacity: 0.22

    SequentialAnimation on opacity {
      running: camp.fresh && camp.visible
      loops: Animation.Infinite
      NumberAnimation { to: 0.34; duration: 1600; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.16; duration: 1600; easing.type: Easing.InOutQuad }
    }
  }

  // ── avatar ────────────────────────────────────────────────────────────
  Rectangle {
    id: ring
    width: camp.size
    height: camp.size
    radius: width / 2
    x: -width / 2
    y: -height / 2
    color: "#F7F5F0"
    border.color: camp.fresh ? "#EB7100" : (camp.hovered ? "#EB7100" : "#4A3F30")
    border.width: camp.fresh ? 3 : 2

    ClippingRectangle {
      anchors.fill: parent
      anchors.margins: ring.border.width + 1
      radius: width / 2
      color: "#4A3F30"

      Image {
        id: face
        anchors.fill: parent
        source: agent.avatar || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Avatars come at 128px; request a crisp mip for the drawn size.
        sourceSize: Qt.size(128, 128)
        visible: status === Image.Ready
      }

      // Fallback: initials on ink, for the 18-ish crew without a picture.
      Text {
        anchors.centerIn: parent
        visible: face.status !== Image.Ready
        text: agent.initials || "?"
        color: "#F7F5F0"
        font.pixelSize: Math.max(11, camp.size * 0.34)
        font.bold: true
      }
    }
  }

  // ── name plate ────────────────────────────────────────────────────────
  Column {
    anchors.horizontalCenter: ring.horizontalCenter
    anchors.top: ring.bottom
    anchors.topMargin: 5
    spacing: 0

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "@" + (agent.username || "?")
      color: "#2C2418"
      font.pixelSize: 13
      style: Text.Outline
      styleColor: "#F7F5F0"
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: !camp.showBubble && camp.ago !== ""
      text: camp.ago
      color: "#7A6E5A"
      font.pixelSize: 11
      style: Text.Outline
      styleColor: "#F7F5F0"
    }
  }

  // ── quote bubble ──────────────────────────────────────────────────────
  Rectangle {
    id: bubble
    visible: camp.showBubble && quote.text !== ""
    width: Math.min(280, quote.implicitWidth + 24)
    height: quoteColumn.implicitHeight + 18
    radius: 10
    color: "#FFFFFF"
    border.color: "#E0DCD4"
    x: camp.bubbleOnLeft ? -(width + camp.size / 2 + 14) : camp.size / 2 + 14
    y: -height - 6 - camp.bubbleRank * 66

    Column {
      id: quoteColumn
      anchors.fill: parent
      anchors.margins: 9
      spacing: 3

      Text {
        id: quote
        width: 260
        text: agent.lastMessage ? "«" + agent.lastMessage + "»" : ""
        color: "#4A3F30"
        font.pixelSize: 12
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
      Text {
        text: camp.ago
        color: "#7A6E5A"
        font.pixelSize: 11
      }
    }

    // Tail toward the avatar.
    Rectangle {
      width: 12
      height: 12
      color: "#FFFFFF"
      border.color: "#E0DCD4"
      rotation: 45
      x: camp.bubbleOnLeft ? parent.width - 8 : -4
      y: parent.height - 16
    }
  }

  MouseArea {
    id: pointer
    x: -camp.size / 2 - 6
    y: -camp.size / 2 - 6
    width: camp.size + 12
    height: camp.size + 12
    enabled: camp.interactive
    hoverEnabled: camp.interactive
    cursorShape: Qt.PointingHandCursor
    onClicked: camp.activated()
    onContainsMouseChanged: camp.hoverChanged(containsMouse)
  }
}
