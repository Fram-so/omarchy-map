import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Fram Kartet — Nansen's 1893–96 expedition map (the one behind the Fram
// chat) as a living layer behind your windows.
//
// Agents who said something recently camp on the map around your basecamp,
// wearing their real profile pictures. How close they pitch is how often you
// talk with them; silence fades them out and after a day they strike camp.
// An empty map is a quiet Fram.
//
// Reads two state files published for it and talks to nothing:
//   ~/.local/state/fram/agents.json  — roster (who exists, avatar, state)
//   ~/.local/state/fram/voices.json  — who said what, when, how often
// `fram-kartet-mock` writes the same voices file, so the whole display can
// be driven without the platform.
//
// Deliberately self-contained: no qs.Commons import, no Omarchy singletons —
// only the documented manifest contract and Quickshell, so it survives an
// `omarchy update` (same principle as fram.lemmings).
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string rosterPath: stateHome + "/fram/agents.json"
  readonly property string voicesPath: stateHome + "/fram/voices.json"
  readonly property string configPath: configHome + "/fram/kartet.json"

  property var roster: null
  property var voices: null
  property var config: ({})
  property bool commandMode: false
  // Scenery look lifted above the windows, input still off — exists so a
  // screenshot can show what an empty desktop looks like without moving
  // anyone's windows.
  property bool previewMode: false
  property var hoveredCamp: null

  // ── settings ──────────────────────────────────────────────────────────
  // Own file, not shell.json: services are constructed without property
  // injection. Re-read within two seconds of a change.
  function num(key, fallback) {
    var value = Number(config[key])
    return isFinite(value) ? value : fallback
  }
  function flag(key, fallback) {
    return config[key] === undefined ? fallback : config[key] === true
  }
  readonly property bool enabled: flag("enabled", true)
  readonly property int maxCamps: Math.max(1, num("maxAgents", 14))
  readonly property real wash: Math.min(0.95, Math.max(0, num("wash", 0.52)))
  readonly property int bubbleCount: Math.max(0, num("bubbles", 3))
  readonly property real ttlHours: Math.max(1, num("ttlHours", 24))
  readonly property real avatarSize: Math.max(28, num("avatarSize", 66))

  // ── data files ────────────────────────────────────────────────────────

  FileView {
    id: rosterFile
    path: root.rosterPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.roster = root.parseOrNull(text())
    onLoadFailed: root.roster = null
  }

  FileView {
    id: voicesFile
    path: root.voicesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.voices = root.parseOrNull(text())
    onLoadFailed: root.voices = null
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = root.parseOrNull(text())
      root.config = parsed || ({})
    }
    onLoadFailed: root.config = ({})
  }

  // The state files are written atomically (tmp + rename), which swaps the
  // inode out from under inotify: the watch survives exactly one update and
  // never sees a file created after startup. Polling covers both cases;
  // watchChanges stays on because when it fires, it fires instantly.
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      rosterFile.reload()
      voicesFile.reload()
      configFile.reload()
    }
  }

  function parseOrNull(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      return null
    }
  }

  // Age drives visibility, so the field must notice time passing even when
  // the files do not change.
  property real nowSec: Date.now() / 1000
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // One input region per camp, tracking its click target's geometry.
  property var campRegions: []

  Component { id: campRegionFactory; Region {} }

  function rebuildCampRegions() {
    var fresh = []
    for (var i = 0; i < campRepeater.count; i++) {
      var slot = campRepeater.itemAt(i)
      if (slot && slot.clickTarget)
        fresh.push(campRegionFactory.createObject(field, { item: slot.clickTarget }))
    }
    var old = root.campRegions
    root.campRegions = fresh
    for (var j = 0; j < old.length; j++) if (old[j]) old[j].destroy()
  }

  // ── the model ─────────────────────────────────────────────────────────
  // voices.json says who spoke; the roster dresses them (name, avatar).
  // Ring = conversation frequency, angle = stable per agent within its ring.
  readonly property var camps: buildCamps(roster, voices, nowSec, maxCamps, ttlHours)

  function hash01(text) {
    var s = String(text || "")
    var hash = 0
    for (var i = 0; i < s.length; i++) hash = (hash * 31 + s.charCodeAt(i)) % 100000
    return hash / 100000
  }

  function ringOf(freq) {
    if (freq >= 20) return 0        // daglig
    if (freq >= 4) return 1         // ukentlig
    return 2                        // sjelden
  }

  function agoText(age) {
    if (age < 90) return "nå nettopp"
    if (age < 3600) return "for " + Math.round(age / 60) + " min siden"
    return "for " + Math.round(age / 3600) + " t siden"
  }

  // Fade with silence: full and glowing under an hour, half-there to six
  // hours, a trace to the TTL, gone after that.
  function fadeOf(age) {
    if (age < 3600) return 1.0
    if (age < 6 * 3600) return 0.62
    return 0.3
  }

  function buildCamps(roster, voices, now, max, ttl) {
    var entries = voices && Array.isArray(voices.voices) ? voices.voices : []
    var agents = roster && Array.isArray(roster.agents) ? roster.agents : []
    var byId = {}
    for (var i = 0; i < agents.length; i++) {
      if (agents[i] && agents[i].id) byId[String(agents[i].id)] = agents[i]
    }

    var out = []
    for (var j = 0; j < entries.length; j++) {
      var voice = entries[j]
      if (!voice || !voice.id) continue
      var at = Number(voice.lastAt) || 0
      var age = Math.max(0, now - at)
      if (age > ttl * 3600) continue
      var agent = byId[String(voice.id)] || ({})
      var username = agent.username || String(voice.id).replace("fram:", "")
      out.push({
        id: String(voice.id),
        username: username,
        name: agent.name || username,
        userId: agent.userId || voice.userId || 0,
        avatar: agent.avatar || voice.avatar || "",
        initials: agent.initials || username.slice(0, 2).toUpperCase(),
        lastMessage: String(voice.lastMessage || ""),
        source: voice.source || null,
        age: age,
        ago: agoText(age),
        fade: fadeOf(age),
        freq: Number(voice.messages30d) || 0,
        ring: ringOf(Number(voice.messages30d) || 0),
        angleFrac: 0
      })
    }

    // Freshest first — that order picks who gets a quote bubble.
    out.sort(function (a, b) { return a.age - b.age })
    out = out.slice(0, max)

    // Spread each ring by sorted username, not by hash alone: hashing a list
    // of similar ids clusters them (the lemmings lesson). The hash only
    // jitters the spacing so the arc doesn't look like a picket fence.
    for (var ring = 0; ring < 3; ring++) {
      var members = out.filter(function (c) { return c.ring === ring })
      members.sort(function (a, b) { return a.username < b.username ? -1 : 1 })
      for (var k = 0; k < members.length; k++) {
        members[k].angleFrac =
          (k + 0.5 + 0.5 * (hash01(members[k].id) - 0.5)) / members.length
      }
    }
    return out
  }

  // ── the map ───────────────────────────────────────────────────────────

  PanelWindow {
    id: field

    visible: root.enabled && (root.camps.length > 0 || root.commandMode || root.previewMode)
    color: "transparent"

    anchors { left: true; right: true; top: true; bottom: true }

    WlrLayershell.namespace: "fram-kartet"
    // Scenery lives under the windows; command mode lifts the same surface
    // above them and gives it input.
    WlrLayershell.layer: (root.commandMode || root.previewMode) ? WlrLayer.Overlay : WlrLayer.Bottom
    WlrLayershell.keyboardFocus: root.commandMode ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Scenery takes input only where the camps are (a region per avatar,
    // rebuilt as camps come and go), so the rest of the map stays pure
    // click-through. Command mode takes the whole surface.
    mask: Region {
      width: root.commandMode ? field.width : 0
      height: root.commandMode ? field.height : 0
      regions: root.commandMode ? [] : root.campRegions
    }

    readonly property real baseX: width / 2
    readonly property real baseY: height - Math.max(96, height * 0.1)
    readonly property var ringRadii: [height * 0.27, height * 0.42, height * 0.56]

    Image {
      anchors.fill: parent
      source: Qt.resolvedUrl("assets/map_cover.jpg")
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
    }

    // Paper wash so the engraving carries markers instead of shouting over
    // the desktop. Command mode trades some wash for a dim.
    Rectangle {
      anchors.fill: parent
      color: "#F7F5F0"
      opacity: root.commandMode ? 0.3 : root.wash
    }
    Rectangle {
      anchors.fill: parent
      color: "#000000"
      opacity: root.commandMode ? 0.24 : 0
    }

    // ── frequency rings ─────────────────────────────────────────────────
    Canvas {
      id: rings
      anchors.fill: parent
      opacity: 0.55
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.strokeStyle = "#4A3F30"
        ctx.lineWidth = 2
        ctx.setLineDash([2, 9])
        for (var i = 0; i < field.ringRadii.length; i++) {
          ctx.beginPath()
          ctx.arc(field.baseX, field.baseY, field.ringRadii[i],
                  Math.PI + 0.18, 2 * Math.PI - 0.18)
          ctx.stroke()
        }
      }
    }

    // Ring names sit at the west end of each arc, out of the camps' way.
    Repeater {
      model: ["daglig", "ukentlig", "sjelden"]
      delegate: Text {
        required property string modelData
        required property int index
        readonly property real theta: Math.PI * 158 / 180
        x: field.baseX + field.ringRadii[index] * Math.cos(theta) - width - 10
        y: field.baseY - field.ringRadii[index] * Math.sin(theta) * 0.92 - height / 2
        text: modelData
        color: "#7A6E5A"
        font.pixelSize: 13
        style: Text.Outline
        styleColor: "#F7F5F0"
        opacity: 0.9
      }
    }

    // ── the camps ───────────────────────────────────────────────────────
    // (The rings still radiate from an invisible point at the bottom — the
    // "you" position — but nothing is drawn there anymore.)
    Repeater {
      id: campRepeater
      model: root.camps
      onItemAdded: Qt.callLater(root.rebuildCampRegions)
      onItemRemoved: Qt.callLater(root.rebuildCampRegions)

      delegate: Camp {
        id: slot
        required property var modelData
        required property int index

        readonly property real radius: field.ringRadii[modelData.ring]
        readonly property real theta: Math.PI * (165 - modelData.angleFrac * 150) / 180
        readonly property real rawX: field.baseX + radius * Math.cos(theta)
        readonly property real rawY: field.baseY - radius * Math.sin(theta) * 0.92

        x: Math.min(field.width - 160, Math.max(160, rawX))
        y: Math.min(field.baseY - 90, Math.max(120, rawY))
        z: 10 + (root.camps.length - index)

        agent: modelData
        size: root.avatarSize
        fresh: modelData.age < 3600
        showBubble: index < root.bubbleCount && modelData.age < 6 * 3600
        // Bubbles point outward from the cluster (west camps carry theirs
        // west), so neighbours' quotes diverge instead of stacking into the
        // middle — except near an edge, where the side that fits wins.
        bubbleOnLeft: rawX > field.width - 480 ? true
                    : rawX < 480 ? false
                    : rawX < field.width / 2
        bubbleRank: index
        ago: modelData.ago
        opacity: modelData.fade

        onActivated: {
          root.openAgent(modelData)
          root.commandMode = false
        }
        onHoverChanged: inside => {
          if (inside) root.hoveredCamp = modelData
          else if (root.hoveredCamp && root.hoveredCamp.id === modelData.id)
            root.hoveredCamp = null
        }
      }
    }

    // ── command mode chrome ─────────────────────────────────────────────
    Rectangle {
      visible: root.commandMode
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: 64
      color: "#0e0e0eee"

      Column {
        anchors.centerIn: parent
        spacing: 4

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          color: "#e8e8e8"
          font.pixelSize: 13
          font.bold: true
          text: root.camps.length === 0
            ? "Stille på kartet — ingen har sagt noe siste døgn"
            : root.camps.length + " stemmer på kartet · klikk en leir for å åpne i Fram"
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          color: "#909090"
          font.pixelSize: 11
          text: {
            var stamp = root.voices && root.voices.updatedAt
              ? "stemmer oppdatert " + String(root.voices.updatedAt).slice(11, 19)
              : "ingen voices-fil — kjør fram-kartet-mock eller Fram Desktop"
            return stamp + " · Esc lukker"
          }
        }
      }
    }

    // Full last message for whatever the pointer rests on.
    Rectangle {
      visible: root.commandMode && root.hoveredCamp !== null
      anchors { left: parent.left; bottom: parent.bottom; margins: 28 }
      width: 420
      height: hoverColumn.implicitHeight + 30
      radius: 12
      color: "#FFFFFF"
      border.color: "#E0DCD4"

      Column {
        id: hoverColumn
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 15 }
        spacing: 6

        Text {
          text: root.hoveredCamp
            ? root.hoveredCamp.name + "  ·  @" + root.hoveredCamp.username
            : ""
          color: "#2C2418"
          font.pixelSize: 14
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.hoveredCamp && root.hoveredCamp.lastMessage
            ? "«" + root.hoveredCamp.lastMessage + "»"
            : ""
          color: "#4A3F30"
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 6
          elide: Text.ElideRight
        }
        Text {
          text: root.hoveredCamp
            ? root.hoveredCamp.ago + " · " + root.hoveredCamp.freq + " meldinger siste 30 d · klikk for å åpne i Fram"
            : ""
          color: "#7A6E5A"
          font.pixelSize: 11
        }
      }
    }

    Item {
      anchors.fill: parent
      focus: root.commandMode
      Keys.onEscapePressed: root.commandMode = false
    }
  }

  // ── actions ───────────────────────────────────────────────────────────
  // A click opens the place the agent's latest message actually lives:
  // its conversation, or the feed post. The routes are handled by Fram
  // Desktop's deep-link handler (fram://conversation, fram://feed).
  function openAgent(camp) {
    if (!camp) return
    var src = camp.source
    var url = "fram://feed"
    if (src && src.kind === "conversation" && src.id)
      url = "fram://conversation?id=" + src.id
    else if (src && src.kind === "feed" && src.id)
      url = "fram://feed?post=" + src.id
    Quickshell.execDetached(["xdg-open", url])
  }

  IpcHandler {
    target: "fram.kartet"

    function toggle(): string { root.commandMode = !root.commandMode; return root.commandMode ? "open" : "closed" }
    function open(): string { root.commandMode = true; return "ok" }
    function close(): string { root.commandMode = false; root.previewMode = false; return "ok" }
    function preview(): string { root.previewMode = !root.previewMode; return root.previewMode ? "on" : "off" }
    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        drawn: root.camps.length,
        commandMode: root.commandMode,
        clickRegions: root.campRegions.length,
        hovered: root.hoveredCamp ? root.hoveredCamp.username : null,
        voicesUpdatedAt: root.voices ? root.voices.updatedAt : null,
        rosterUpdatedAt: root.roster ? root.roster.updatedAt : null
      })
    }

    // Camp screen positions — lets a script park the cursor on one to verify
    // the scenery input mask end to end.
    function camps(): string {
      var out = []
      for (var i = 0; i < campRepeater.count; i++) {
        var slot = campRepeater.itemAt(i)
        if (slot) out.push({ u: slot.modelData.username, x: Math.round(slot.x), y: Math.round(slot.y) })
      }
      return JSON.stringify(out)
    }
  }
}
