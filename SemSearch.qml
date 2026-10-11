import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick 6.11
import qs.Commons
import qs.Ui

// Overlay for semsearchd. All ranking, snippets and page rendering happen in
// the daemon; this file sends JSON lines down its socket and draws the replies.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string query: ""
  property var rows: []
  property int selectedIndex: 0
  readonly property var hit: root.rows[root.selectedIndex] || null
  property var preview: ({})
  property var status: ({})
  property bool waiting: false
  // Off: hits by meaning only. On: also the literal words and file paths.
  property bool wordMatch: false
  // What the hits are narrowed to. It only filters: All finds the same hits.
  property string kind: "all"
  readonly property var kinds: [
    { id: "all", label: "All" },
    { id: "text", label: "Documents" },
    { id: "code", label: "Code" },
    { id: "image", label: "Pictures" }
  ]

  // Replies are matched to the latest request of their kind, so an answer to
  // a query the user has since typed past is dropped.
  property int lastId: 0
  property int searchId: 0
  property int previewId: 0

  readonly property string socketPath: Quickshell.env("XDG_RUNTIME_DIR") + "/semsearch.sock"
  readonly property string openScript: decodeURIComponent(Qt.resolvedUrl("open-hit").toString().replace(/^file:\/\//, ""))
  readonly property int minQueryLength: 2

  // Shares the [menu] surface tokens, like the other summoned overlays.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color accent: Color.menu.selectedText
  readonly property color highlight: "#ffd400"
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  property int cardWidth: Math.min(Style.space(1100), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)
  property int headerHeight: Style.font.display + Style.space(20)
  property int footerHeight: Style.font.caption + Style.space(12)
  property int rowHeight: Style.font.title + Style.font.bodySmall + Style.space(22)
  property int gap: Style.spacing.panelGap

  function open(payloadJson) {
    // The payload may carry a query and a kind, so a key can be bound to,
    // say, a picture search: '{"kind":"image"}'.
    var payload = {}
    try {
      payload = JSON.parse(payloadJson || "{}") || {}
    } catch (e) {}
    var known = root.kinds.some(function(k) { return k.id === payload.kind })

    root.opened = true
    sock.connected = true
    root.kind = known ? payload.kind : "all"
    root.setQuery(String(payload.query || ""))
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    sock.connected = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "depletionmode.semsearch")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --- Daemon ---------------------------------------------------------------

  function send(request) {
    if (!sock.connected) return 0
    request.id = ++root.lastId
    sock.write(JSON.stringify(request) + "\n")
    sock.flush()
    return request.id
  }

  function receive(line) {
    var reply
    try {
      reply = JSON.parse(line)
    } catch (e) {
      return
    }
    root.status = reply.status || {}

    if (reply.op === "search" && reply.id === root.searchId) {
      root.rows = reply.hits || []
      root.selectedIndex = 0
      // While the model loads the daemon answers with the word matches alone
      // and follows up with the full ranking under the same id.
      root.waiting = reply.partial === true
      resultList.positionViewAtBeginning()
      root.requestPreview()
    } else if (reply.op === "preview" && reply.id === root.previewId) {
      root.preview = reply.preview || {}
    }
  }

  function setQuery(text) {
    root.query = text
    if (text.trim().length < root.minQueryLength) {
      typingPause.stop()
      root.searchId = 0
      root.rows = []
      root.preview = {}
      root.waiting = false
    } else {
      root.waiting = true
      typingPause.restart()
    }
  }

  function search() {
    root.searchId = root.send({ op: "search", q: root.query.trim(), words: root.wordMatch, kind: root.kind })
  }

  function setKind(id) {
    root.kind = id
    root.setQuery(root.query)
  }

  function cycleKind() {
    for (var i = 0; i < root.kinds.length; i++) {
      if (root.kinds[i].id === root.kind) {
        root.setKind(root.kinds[(i + 1) % root.kinds.length].id)
        return
      }
    }
  }

  function toggleWordMatch() {
    root.wordMatch = !root.wordMatch
    root.setQuery(root.query)
  }

  function requestPreview() {
    root.preview = {}
    if (root.hit)
      root.previewId = root.send({ op: "preview", chunk: root.hit.chunk, q: root.query.trim() })
  }

  function move(delta) {
    if (root.rows.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    selectionPause.restart()
  }

  // --- Actions --------------------------------------------------------------

  // Paths go through execArgv so nothing in a filename is read by a shell.
  function openHit() {
    if (!root.hit) return
    // Opens a PDF at the matching page and source at the matching line.
    Util.execArgv(["setsid", "uwsm-app", "--", root.openScript,
                   root.hit.path, String(root.hit.page), String(root.hit.line)])
    root.dismiss()
  }

  function revealHit() {
    if (!root.hit) return
    // GVariant strings are single-quoted, so an apostrophe has to be encoded.
    var uri = Util.fileUrl(root.hit.path).replace(/'/g, "%27")
    Util.execArgv(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                   "--object-path", "/org/freedesktop/FileManager1",
                   "--method", "org.freedesktop.FileManager1.ShowItems", "['" + uri + "']", ""])
    root.dismiss()
  }

  function copyPath() {
    if (!root.hit) return
    Util.execArgv(["wl-copy", "--", root.hit.path])
    root.dismiss()
  }

  // --- Presentation ---------------------------------------------------------

  // Nerd Font glyphs: code, image, PDF, word processor, plain text.
  function glyph(row) {
    if (row.line) return "\uf121"
    if (row.image) return "\uf1c5"
    if (row.ext === "pdf") return "\uf1c1"
    if (row.ext === "docx" || row.ext === "odt") return "\uf1c2"
    return "\uf15c"
  }

  function reason(why) {
    if (why === "words") return "Has your words"
    if (why === "name") return "Name matches"
    if (why === "looks") return "Looks like it"
    return "Similar meaning"
  }

  function formatSize(bytes) {
    var units = ["B", "KB", "MB", "GB"]
    var n = bytes
    var u = 0
    while (n >= 1024 && u < units.length - 1) {
      n /= 1024
      u++
    }
    return Math.round(n) + " " + units[u]
  }

  function facts(row) {
    var parts = [row.ext.toUpperCase(), Qt.formatDate(new Date(row.mtime * 1000), "MMM d, yyyy")]
    if (row.pages) parts.push(row.pages + (row.pages === 1 ? " page" : " pages"))
    parts.push(root.formatSize(row.size))
    return parts.join("  ·  ")
  }

  readonly property string statusLine: {
    if (!sock.connected) return "semsearchd is not running"
    if (root.waiting) return root.rows.length ? "Matching words… loading model" : "Matching…"
    var s = root.status
    if (s.total > 0) return "Indexing " + s.done + " of " + s.total + "…"
    if (s.files === undefined) return ""
    return s.files + " files indexed" + (s.loaded ? "" : "  ·  model unloaded")
  }

  readonly property string emptyLine: {
    if (!sock.connected) return "semsearchd is not running — run install.sh in the plugin folder"
    if (root.query.trim().length < root.minQueryLength) return "Describe what you are looking for"
    if (root.waiting) return "Matching…"
    return "Nothing matches “" + root.query.trim() + "”"
  }

  Socket {
    id: sock
    path: root.socketPath
    parser: SplitParser {
      onRead: function(line) { root.receive(line) }
    }
    onConnectionStateChanged: {
      if (!sock.connected) return
      // Loads the model while the first query is still being typed.
      root.send({ op: "warm" })
      if (root.waiting) root.search()
    }
  }

  // Reconnects if the daemon was restarted, and keeps the indexing count live.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: {
      if (sock.connected) root.send({ op: "status" })
      else sock.connected = true
    }
  }

  Timer {
    id: typingPause
    interval: 140
    onTriggered: root.search()
  }

  // Holding an arrow key should not render a page per row passed.
  Timer {
    id: selectionPause
    interval: 70
    onTriggered: root.requestPreview()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-semsearch"
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
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          event.accepted = true
          if (event.key === Qt.Key_Escape) {
            if (root.query) root.setQuery("")
            else root.dismiss()
          } else if (Util.editsFilter(event, root.query)) {
            root.setQuery(Util.editedFilter(event, root.query))
          } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            // Shift+Tab arrives as either, depending on the keyboard layout.
            root.toggleWordMatch()
          } else if (event.key === Qt.Key_Tab) {
            root.cycleKind()
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-6)
          } else if (event.key === Qt.Key_PageDown) {
            root.move(6)
          } else if (enter && (event.modifiers & Qt.ShiftModifier)) {
            root.revealHit()
          } else if (enter) {
            root.openHit()
          } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
            root.copyPath()
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setQuery(root.query + event.text)
          } else {
            event.accepted = false
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // --- Query ---
        Item {
          id: header
          width: parent.width
          height: root.headerHeight

          Text {
            id: lens
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf002"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            id: queryText
            textFormat: Text.PlainText
            anchors.left: lens.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - lens.width - controls.width - Style.space(40))
            text: root.query || "Search by meaning…"
            color: root.foreground
            opacity: root.query ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.display * 0.8
            elide: Text.ElideLeft
          }

          Rectangle {
            visible: root.query !== ""
            anchors.left: queryText.right
            anchors.leftMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(2)
            height: queryText.height * 0.8
            color: root.accent

            SequentialAnimation on opacity {
              running: root.opened
              loops: Animation.Infinite
              NumberAnimation { to: 0; duration: 500; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutQuad }
            }
          }

          // What to look in, then how to match.
          Row {
            id: controls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: root.kinds.concat([{ id: "words", label: "" }])

              Rectangle {
                id: chip
                required property var modelData
                readonly property bool isMode: modelData.id === "words"
                readonly property bool active: isMode ? root.wordMatch : root.kind === modelData.id

                width: chipLabel.implicitWidth + Style.space(18)
                height: chipLabel.implicitHeight + Style.space(10)
                radius: root.cornerRadius
                color: chip.active ? root.selectedBackground : Util.alpha(root.foreground, 0.06)

                Text {
                  id: chipLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: chip.isMode ? (root.wordMatch ? "Meaning + words" : "Meaning") : chip.modelData.label
                  color: chip.active ? root.accent : root.foreground
                  opacity: chip.active ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: chip.isMode ? root.toggleWordMatch() : root.setKind(chip.modelData.id)
                }
              }
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.12)
          }
        }

        // --- Results ---
        Item {
          id: body
          anchors.top: header.bottom
          anchors.topMargin: root.gap
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.space(8)
          width: parent.width

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.rows.length === 0
            text: root.emptyLine
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          ListView {
            id: resultList
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.round(parent.width * 0.4)
            model: root.rows
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property var modelData
              readonly property bool current: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: current ? root.selectedBackground : "transparent"

              Item {
                id: badge
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: root.rowHeight - Style.space(12)
                height: width

                Text {
                  anchors.centerIn: parent
                  visible: thumb.status !== Image.Ready
                  text: root.glyph(row.modelData)
                  color: row.current ? root.accent : root.foreground
                  opacity: row.current ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display * 0.8
                }

                Image {
                  id: thumb
                  anchors.fill: parent
                  source: row.modelData.image ? Util.fileUrl(row.modelData.path) : ""
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                }
              }

              Text {
                id: pageTag
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.baseline: nameText.baseline
                visible: row.modelData.page > 0 || row.modelData.line > 0
                text: row.modelData.page > 0 ? "p. " + row.modelData.page : "line " + row.modelData.line
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: nameText
                textFormat: Text.PlainText
                anchors.left: badge.right
                anchors.leftMargin: Style.space(10)
                anchors.right: pageTag.visible ? pageTag.left : parent.right
                anchors.rightMargin: Style.space(10)
                anchors.top: parent.top
                anchors.topMargin: Style.space(9)
                text: row.modelData.name
                color: row.current ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideMiddle
              }

              Text {
                // The daemon escapes the passage; the only markup is its <b>.
                textFormat: row.modelData.snippet ? Text.StyledText : Text.PlainText
                anchors.left: nameText.left
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.top: nameText.bottom
                anchors.topMargin: Style.space(3)
                text: row.modelData.snippet || row.modelData.dir
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                maximumLineCount: 1
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (row.current) {
                    root.openHit()
                  } else {
                    root.selectedIndex = row.index
                    root.requestPreview()
                  }
                }
              }
            }
          }

          // --- Preview ---
          Item {
            id: pane
            anchors.left: resultList.right
            anchors.leftMargin: root.gap
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            visible: root.hit !== null

            Item {
              id: stage
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: Math.round(parent.height * 0.58)
              clip: true

              // A text passage fills the stage and a picture is fitted into it.
              // A page is shown at full width, readable, scrolled to the match.
              readonly property bool paged: root.hit !== null && root.hit.page > 0 && !!root.preview.image
              readonly property real aspect: root.preview.aspect || height / width
              readonly property real sheetHeight: paged ? width * aspect : Math.min(height, width * aspect)
              readonly property var anchorRect: (root.preview.terms || [])[0] || (root.preview.passage || [])[0] || [0, 0, 0, 0]

              Rectangle {
                id: sheet
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.round(Math.min(0, Math.max(stage.height - height, stage.height * 0.4 - stage.anchorRect[1] * height)))
                width: Math.round(stage.sheetHeight / stage.aspect)
                height: Math.round(stage.sheetHeight)
                radius: Style.space(4)
                color: root.hit && root.hit.image ? "transparent" : root.preview.code ? Util.alpha(root.foreground, 0.07) : "#ffffff"
                clip: true

                // Source, with the line numbers the daemon put in front.
                Text {
                  textFormat: Text.PlainText
                  anchors.fill: parent
                  anchors.margins: Style.space(14)
                  visible: !!root.preview.code
                  text: root.preview.code || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.NoWrap
                  clip: true
                }

                Image {
                  anchors.fill: parent
                  source: root.preview.image ? Util.fileUrl(root.preview.image) : ""
                  sourceSize.width: stage.width * 2
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                  mipmap: true
                }

                // The passage that matched, then the query's own words in it.
                Repeater {
                  model: root.preview.passage || []
                  Rectangle {
                    required property var modelData
                    x: modelData[0] * sheet.width
                    y: modelData[1] * sheet.height
                    width: modelData[2] * sheet.width
                    height: modelData[3] * sheet.height
                    color: Util.alpha(root.highlight, 0.2)
                  }
                }

                Repeater {
                  model: root.preview.terms || []
                  Rectangle {
                    required property var modelData
                    x: modelData[0] * sheet.width
                    y: modelData[1] * sheet.height
                    width: modelData[2] * sheet.width
                    height: modelData[3] * sheet.height
                    color: Util.alpha(root.highlight, 0.5)
                  }
                }

                Text {
                  textFormat: Text.StyledText
                  anchors.fill: parent
                  anchors.margins: Style.space(22)
                  visible: !!root.preview.text
                  text: root.preview.text || ""
                  color: "#222222"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  lineHeight: 1.35
                  wrapMode: Text.Wrap
                  elide: Text.ElideRight
                }
              }

              Rectangle {
                visible: root.hit !== null && root.hit.page > 0
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(8)
                width: pageLabel.implicitWidth + Style.space(14)
                height: pageLabel.implicitHeight + Style.space(6)
                radius: height / 2
                color: "#cc333333"

                Text {
                  id: pageLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.hit ? "p. " + root.hit.page : ""
                  color: "#ffffff"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Column {
              anchors.top: stage.bottom
              anchors.topMargin: root.gap
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(5)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.hit ? root.hit.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideMiddle
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.hit ? root.hit.dir : ""
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.hit ? root.facts(root.hit) : ""
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Item { width: 1; height: Style.space(4) }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.hit ? root.reason(root.hit.why) : ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                textFormat: Text.StyledText
                width: parent.width
                visible: text !== ""
                text: root.hit ? root.hit.snippet : ""
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Item { width: 1; height: Style.space(4) }

              Row {
                spacing: Style.space(8)

                Repeater {
                  model: [
                    { label: "Open", primary: true },
                    { label: "Show in folder", primary: false }
                  ]

                  Rectangle {
                    id: action
                    required property var modelData
                    width: actionLabel.implicitWidth + Style.space(24)
                    height: actionLabel.implicitHeight + Style.space(12)
                    radius: root.cornerRadius
                    color: modelData.primary ? root.accent : Util.alpha(root.foreground, 0.12)

                    Text {
                      id: actionLabel
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: action.modelData.label
                      color: action.modelData.primary ? root.background : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: action.modelData.primary ? root.openHit() : root.revealHit()
                    }
                  }
                }
              }
            }
          }
        }

        // --- Status and keys ---
        Item {
          id: footer
          anchors.bottom: parent.bottom
          width: parent.width
          height: root.footerHeight

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.12)
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            text: root.statusLine
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: "⇥ Kind    ⇧⇥ Word matches " + (root.wordMatch ? "on" : "off") + "    ↵ Open    ⇧↵ Show in folder    ^C Copy path"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
