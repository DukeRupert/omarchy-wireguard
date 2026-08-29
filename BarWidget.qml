import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A WireGuard tunnel is either carrying your traffic or it is not, and the only
// honest way to know which is to ask NetworkManager rather than to remember what
// the last click did. A reboot, a suspend, or an `nmcli` in a terminal all change
// the answer without going through this widget.
//
// Everything here is readable without privileges: `nmcli` for state and peer
// config, /sys/class/net/<dev>/statistics for counters. `wg show` would give
// handshake times too, but it needs root, and a bar widget has no way to ask.
Panel {
  id: root
  moduleName: "io.github.dukerupert.wireguard"
  ipcTarget: "wireguard"
  // The base's handler would bind `toggle` to the popup. Connecting the VPN is
  // this widget's headline action and the one worth having on a hotkey, so the
  // handler below spends `toggle` on that and gives the popup `panel`.
  manageIpc: false

  // Empty means "whichever WireGuard connection exists", which is what makes an
  // import from the panel work with no configuration afterwards.
  readonly property string connectionName: String(setting("connectionName", ""))
  property string resolvedName: ""
  property string uuid: ""
  // What every command and label should use: the configured name if there is
  // one, otherwise whatever the poll found.
  readonly property string activeName: resolvedName !== "" ? resolvedName : connectionName
  // `nmcli monitor` reports changes as they happen, so this poll is only a
  // safety net for anything it misses — and the cadence while the panel is
  // open, where live throughput needs regular samples.
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 30)))
  // Pinged only while the popup is open, so an idle bar costs nothing. Empty
  // (the default) disables the latency row: there is no address that is right
  // for every tunnel, and silently pinging a guess is worse than showing nothing.
  readonly property string pingTarget: String(setting("pingTarget", ""))

  // known: the profile exists in NetworkManager at all. Without it the widget
  // would sit there looking merely disconnected when the real problem is that
  // the connection was never imported.
  property bool known: false
  property bool connected: false
  // A tunnel comes up in well under a second, but `nmcli` does not return until
  // it has, so the icon would otherwise sit on its stale state for the whole
  // handshake. Holding a transitional flag keeps the click feeling answered.
  property bool busy: false

  property string device: ""
  property var addresses4: []
  property var addresses6: []
  property var peers: []

  property real rxBytes: -1
  property real txBytes: -1
  property real rxRate: 0
  property real txRate: 0
  property real lastSampleMs: 0

  property real latencyMs: -1
  property bool pinging: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool fullTunnel: Model.isFullTunnel(peers)
  readonly property string address4Text: addresses4.length ? addresses4.join(", ") : ""
  readonly property string address6Text: addresses6.length ? addresses6.join(", ") : ""
  readonly property string routesText: Model.routeSummary(peers)
  readonly property string endpointText: peers.length === 1 ? peers[0].endpoint : ""

  readonly property string stateLabel: !known
    ? "Not configured"
    : busy ? (connected ? "Disconnecting…" : "Connecting…")
      : connected ? "Connected" : "Disconnected"

  // ------------------------------------------------------------- formatting

  function formatBytes(n) { return Model.formatBytes(n) }
  function formatRate(bytesPerSecond) { return connected ? Model.formatRate(bytesPerSecond) : "—" }

  function formatLatency() {
    if (!connected || pingTarget === "") return "—"
    if (pinging && latencyMs < 0) return "…"
    return latencyMs < 0 ? "unreachable" : latencyMs.toFixed(1) + " ms"
  }

  // ------------------------------------------------------------------ verbs

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function toggleConnection() {
    if (busy || !known || uuid === "") return
    busy = true
    toggleProc.command = ["nmcli", "connection", connected ? "down" : "up", "uuid", uuid]
    toggleProc.running = true
  }

  // Importing runs in a terminal rather than in here: it needs a file picker and
  // it raises a polkit prompt, and neither belongs in a bar popup.
  readonly property string importScript:
    String(Qt.resolvedUrl("import-config")).replace(/^file:\/\//, "")

  function importConfig() {
    if (!bar) return
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation "
      + bar.shellQuote(importScript))
  }

  function resetCounters() {
    rxBytes = -1
    txBytes = -1
    rxRate = 0
    txRate = 0
    lastSampleMs = 0
    latencyMs = -1
  }

  function sampleCounters(rx, tx) {
    var now = Date.now()
    // Counters live with the interface, so a tunnel that went down and came back
    // restarts from zero. Treating that as a delta would spike the rate chart;
    // treating it as a fresh baseline is what actually happened.
    if (lastSampleMs > 0 && rx >= rxBytes && tx >= txBytes) {
      var seconds = (now - lastSampleMs) / 1000
      if (seconds > 0.2) {
        rxRate = (rx - rxBytes) / seconds
        txRate = (tx - txBytes) / seconds
      }
    } else {
      rxRate = 0
      txRate = 0
    }
    rxBytes = rx
    txBytes = tx
    lastSampleMs = now
  }

  // ------------------------------------------------------------------- poll

  // Every command keys off the connection UUID rather than its name: nmcli's
  // terse output escapes ":" and "\" inside a name, and unescaping that through
  // a QML string literal into a shell is three layers of quoting to get wrong.
  // A UUID is hex and dashes, so it survives every layer untouched.
  readonly property string pollScript: '
n="$1"
if [ -n "$n" ]; then
  u=$(nmcli -g connection.uuid connection show "$n" 2>/dev/null)
else
  u=$(nmcli -t -f TYPE,UUID connection show 2>/dev/null | sed -n "s/^wireguard://p" | head -1)
fi
[ -n "$u" ] || { echo "known=0"; exit 0; }
echo "known=1"
echo "uuid=$u"
echo "name=$(nmcli -g connection.id connection show uuid "$u" 2>/dev/null)"
echo "state=$(nmcli -g GENERAL.STATE connection show uuid "$u" 2>/dev/null)"
d=$(nmcli -g GENERAL.DEVICES connection show uuid "$u" 2>/dev/null)
echo "device=$d"
echo "address4=$(nmcli -g IP4.ADDRESS connection show uuid "$u" 2>/dev/null | paste -sd, -)"
echo "address6=$(nmcli -g IP6.ADDRESS connection show uuid "$u" 2>/dev/null | paste -sd, -)"
nmcli -g wireguard.peers connection show uuid "$u" 2>/dev/null | while IFS= read -r p; do
  [ -n "$p" ] && echo "peer=$p"
done
if [ -n "$d" ] && [ -r "/sys/class/net/$d/statistics/rx_bytes" ]; then
  echo "rx=$(cat "/sys/class/net/$d/statistics/rx_bytes")"
  echo "tx=$(cat "/sys/class/net/$d/statistics/tx_bytes")"
fi
'

  Process {
    id: stateProc
    command: ["bash", "-c", root.pollScript, "wg-poll", root.connectionName]
    onExited: if (!root.known) { root.resolvedName = ""; root.uuid = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parsePoll(text)
        root.known = next.known
        root.resolvedName = next.name
        root.uuid = next.uuid
        if (root.connected && !next.connected) root.resetCounters()
        root.connected = next.connected
        root.device = next.device
        root.addresses4 = next.addresses4
        root.addresses6 = next.addresses6
        root.peers = next.peers
        if (next.rx >= 0 && next.tx >= 0) root.sampleCounters(next.rx, next.tx)
      }
    }
  }

  // NetworkManager announces every state change, so the icon reacts the moment
  // the tunnel moves — including when something else moved it. Without this the
  // bar could be a whole poll interval out of date after `nmcli` in a terminal.
  Process {
    running: true
    command: ["nmcli", "monitor"]
    stdout: SplitParser {
      onRead: function() { settleTimer.restart() }
    }
  }

  // One connect emits a dozen lines in a burst; refreshing on each would mean a
  // dozen subprocesses to learn one outcome.
  Timer {
    id: settleTimer
    interval: 300
    onTriggered: root.refresh()
  }

  Process {
    id: toggleProc
    onExited: {
      root.busy = false
      root.resetCounters()
      root.refresh()
    }
  }

  Process {
    id: pingProc
    command: ["ping", "-n", "-c", "1", "-W", "2", root.pingTarget]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var match = /time=([0-9.]+) *ms/.exec(String(text || ""))
        root.latencyMs = match ? Number(match[1]) : -1
        root.pinging = false
      }
    }
  }

  function measureLatency() {
    if (!connected || pingTarget === "" || pingProc.running) return
    pinging = true
    pingProc.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Latency costs a subprocess and a round trip, so it is only measured while
  // someone is looking at it.
  Timer {
    interval: 5000
    running: root.opened && root.connected && root.pingTarget !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.measureLatency()
  }

  onOpenedChanged: if (opened) refresh()

  IpcHandler {
    target: "wireguard"

    function toggle(): void { root.toggleConnection() }
    function connect(): void { if (!root.connected) root.toggleConnection() }
    function disconnect(): void { if (root.connected) root.toggleConnection() }
    function refresh(): void { root.refresh() }
    function panel(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function status(): string { return root.stateLabel }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    // The tunnel being up is the normal, quiet state, not an alarm — so it reads
    // in the ordinary foreground and only the off state is dimmed.
    useActiveColor: false
    dimmed: !root.connected
    tooltipText: root.known
      ? "WireGuard: " + root.stateLabel.toLowerCase() + " (" + root.activeName + ")"
      : "WireGuard: no tunnel configured"
    onPressed: function(code) {
      if (code === Qt.RightButton) root.toggleConnection()
      else if (code === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.toggleConnection()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") root.toggleConnection()
        else if (t === "r" || t === "R") root.refresh()
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

          PanelHero {
            width: parent.width
            title: "WireGuard"
            meta: root.stateLabel
            detail: root.activeName
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰖂"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰐥"
                tooltipText: root.connected ? "Disconnect" : "Connect"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                visible: root.known
                onClicked: root.toggleConnection()
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: root.known
          }

          PanelSectionHeader {
            width: parent.width
            text: "Tunnel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.known
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.known

            InfoPair {
              label: root.addresses6.length ? "Address (v4)" : "Address"
              value: root.address4Text === "" ? "—" : root.address4Text
              visible: root.addresses4.length > 0 || root.addresses6.length === 0
            }
            InfoPair {
              label: "Address (v6)"
              value: root.address6Text
              visible: root.addresses6.length > 0
            }
            // One peer is the common case and reads best as a plain row; a mesh
            // gets its own section below rather than an endpoint chosen at random.
            InfoPair {
              label: "Endpoint"
              value: root.endpointText === "" ? "—" : root.endpointText
              visible: root.peers.length <= 1
            }
            InfoPair { label: "Peers"; value: String(root.peers.length); visible: root.peers.length > 1 }
            InfoPair { label: "Routes"; value: root.routesText === "" ? "—" : root.routesText }
            InfoPair { label: "Interface"; value: root.device === "" ? "—" : root.device }
            InfoPair {
              label: "Latency"
              value: root.formatLatency()
              visible: root.pingTarget !== ""
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: root.peers.length > 1
          }

          PanelSectionHeader {
            width: parent.width
            text: "Peers"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.peers.length > 1
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.peers.length > 1

            Repeater {
              model: root.peers
              InfoPair {
                required property var modelData
                label: Model.shortKey(modelData.publicKey)
                value: modelData.endpoint === ""
                  ? (modelData.allowedIps.join(", ") || "—")
                  : modelData.endpoint
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: root.known
          }

          PanelSectionHeader {
            width: parent.width
            text: "Transfer"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.known
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.known

            InfoPair { label: "↓ Received"; value: root.formatBytes(root.rxBytes) }
            InfoPair { label: "↑ Sent"; value: root.formatBytes(root.txBytes) }
            InfoPair { label: "↓ Down"; value: root.formatRate(root.rxRate) }
            InfoPair { label: "↑ Up"; value: root.formatRate(root.txRate) }
          }

          // The empty state is the only place most people will ever need help,
          // so it offers the action rather than a command to copy.
          Column {
            width: parent.width
            visible: !root.known
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: root.connectionName === ""
                ? "No WireGuard tunnel is set up yet."
                : "No NetworkManager connection named “" + root.connectionName + "”."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Import a .conf from your VPN provider or your own server."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Import a config…"
              iconText: "󰕒"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.importConfig()
            }
          }

          Text {
            width: parent.width
            visible: root.known
            text: "t toggle · r refresh · esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: visible ? Math.max(labelText.implicitHeight, valueText.implicitHeight) : 0
    height: implicitHeight

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }
}
