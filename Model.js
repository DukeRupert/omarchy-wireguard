.pragma library

// Parsing lives here rather than in the QML so it can be exercised from node
// against configurations this machine does not have — multiple peers, IPv6
// tunnels, split routing. See tests/model-test.js.

// nmcli's terse output escapes ":" as "\:" and "\" as "\\" inside a field.
function unescapeTerse(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/\\(.)/g, "$1")
}

// A peer renders as
//   <pubkey> allowed-ips=0.0.0.0/0;\:\:/0 endpoint=1.2.3.4\:51820 persistent-keepalive=25
// with the key first and the rest as space-separated key=value pairs. Values
// never contain an unescaped space, so splitting on space is safe.
function parsePeer(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  var parts = text.split(" ")
  var peer = { publicKey: unescapeTerse(parts[0]), endpoint: "", allowedIps: [], keepalive: 0 }
  for (var i = 1; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq === -1) continue
    var key = parts[i].substring(0, eq)
    var value = unescapeTerse(parts[i].substring(eq + 1))
    if (key === "endpoint") peer.endpoint = value
    else if (key === "allowed-ips") peer.allowedIps = value.split(";").filter(function(v) { return v !== "" })
    else if (key === "persistent-keepalive") peer.keepalive = Number(value) || 0
  }
  return peer
}

// A tunnel only carries everything if some peer claims a default route. Checking
// just 0.0.0.0/0 would call a v6-default tunnel "split", which is backwards.
function isFullTunnel(peers) {
  for (var i = 0; i < peers.length; i++) {
    var allowed = peers[i].allowedIps
    for (var j = 0; j < allowed.length; j++) {
      if (allowed[j] === "0.0.0.0/0" || allowed[j] === "::/0") return true
    }
  }
  return false
}

// Link-local is assigned to the interface whether or not the tunnel routes v6,
// so showing it would imply an IPv6 tunnel that may not exist.
function usableAddresses(raw) {
  return String(raw || "").split(",")
    .map(function(v) { return v.trim() })
    .filter(function(v) { return v !== "" && v.toLowerCase().indexOf("fe80:") !== 0 })
}

function parsePoll(text) {
  var state = {
    known: false, connected: false, name: "", uuid: "", device: "",
    addresses4: [], addresses6: [], peers: [], profiles: [],
    rx: -1, tx: -1
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq <= 0) continue
    var key = lines[i].substring(0, eq)
    var value = lines[i].substring(eq + 1)
    if (key === "known") state.known = value === "1"
    else if (key === "name") state.name = value
    else if (key === "uuid") state.uuid = value
    else if (key === "state") state.connected = value === "activated"
    else if (key === "device") state.device = value
    else if (key === "address4") state.addresses4 = usableAddresses(value)
    else if (key === "address6") state.addresses6 = usableAddresses(value)
    else if (key === "peer") { var p = parsePeer(value); if (p) state.peers.push(p) }
    else if (key === "profile") {
      var tab = value.indexOf("\t")
      if (tab > 0) state.profiles.push({ uuid: value.substring(0, tab), name: value.substring(tab + 1) })
    }
    else if (key === "rx") state.rx = Number(value)
    else if (key === "tx") state.tx = Number(value)
  }
  return state
}

// The profile after the current one, wrapping, so repeated swaps cycle through
// every mode. Null when there is nothing to swap to.
function nextProfile(profiles, currentUuid) {
  if (!profiles || profiles.length < 2) return null
  for (var i = 0; i < profiles.length; i++) {
    if (profiles[i].uuid === currentUuid) return profiles[(i + 1) % profiles.length]
  }
  return profiles[0]
}

function routeSummary(peers) {
  if (peers.length === 0) return ""
  if (isFullTunnel(peers)) return "All traffic"
  var seen = {}
  var all = []
  for (var i = 0; i < peers.length; i++) {
    for (var j = 0; j < peers[i].allowedIps.length; j++) {
      var cidr = peers[i].allowedIps[j]
      if (seen[cidr]) continue
      seen[cidr] = true
      all.push(cidr)
    }
  }
  if (all.length <= 3) return all.join(", ")
  return all.slice(0, 3).join(", ") + " +" + (all.length - 3)
}

function formatBytes(n) {
  if (n === undefined || n === null || !(n >= 0)) return "—"
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var value = Number(n)
  var i = 0
  while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
  return (i === 0 ? value.toFixed(0) : value.toFixed(value < 10 ? 2 : 1)) + " " + units[i]
}

// Rates read as bits per second everywhere else in networking; matching that
// avoids a number that looks eight times too slow next to a speed test.
function formatRate(bytesPerSecond) {
  if (bytesPerSecond === undefined || bytesPerSecond === null || !(bytesPerSecond >= 0)) return "—"
  var bits = Number(bytesPerSecond) * 8
  var units = ["bps", "Kbps", "Mbps", "Gbps"]
  var i = 0
  while (bits >= 1000 && i < units.length - 1) { bits /= 1000; i++ }
  return (i === 0 ? bits.toFixed(0) : bits.toFixed(bits < 10 ? 1 : 0)) + " " + units[i]
}

function shortKey(publicKey) {
  var k = String(publicKey || "")
  return k.length > 12 ? k.substring(0, 8) + "…" : k
}
