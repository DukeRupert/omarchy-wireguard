// Run with: node tests/model-test.js
// Model.js is QML JS: strip the .pragma line and eval it here.
const fs = require("fs")
const path = require("path")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = {}
new Function("exports", src + "\n;Object.assign(exports,{parsePeer,isFullTunnel,usableAddresses,parsePoll,routeSummary,nextProfile,formatBytes,formatRate,shortKey,unescapeTerse})")(M)

let failed = 0
function eq(label, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a !== e) { console.log(`FAIL ${label}\n  got      ${a}\n  expected ${e}`); failed++ }
  else console.log(`ok   ${label}`)
}

// --- the real single-peer, full-tunnel case on this machine ---------------
const real = [
  "known=1", "state=activated", "device=wg0",
  "address4=10.0.0.7/32", "address6=",
  "peer=dqK72drYiE3NHgzrmx3U9LDTp0fOkQHi6qb19mX3FX4= allowed-ips=0.0.0.0/0;\\:\\:/0 endpoint=5.78.95.174\\:51820 persistent-keepalive=25",
  "rx=522668", "tx=2012056"
].join("\n")
const r = M.parsePoll(real)
eq("real: connected", r.connected, true)
eq("real: device", r.device, "wg0")
eq("real: v4", r.addresses4, ["10.0.0.7/32"])
eq("real: v6 empty", r.addresses6, [])
eq("real: one peer", r.peers.length, 1)
eq("real: endpoint unescaped", r.peers[0].endpoint, "5.78.95.174:51820")
eq("real: allowed-ips unescaped", r.peers[0].allowedIps, ["0.0.0.0/0", "::/0"])
eq("real: keepalive", r.peers[0].keepalive, 25)
eq("real: full tunnel", M.isFullTunnel(r.peers), true)
eq("real: routes", M.routeSummary(r.peers), "All traffic")
eq("real: counters", [r.rx, r.tx], [522668, 2012056])

// --- multi-peer mesh, split routes ---------------------------------------
const mesh = [
  "known=1", "state=activated", "device=wg0", "address4=10.10.0.5/24", "address6=",
  "peer=AAAA= allowed-ips=10.10.0.1/32 endpoint=vpn.example.com\\:51820",
  "peer=BBBB= allowed-ips=10.10.0.2/32;192.168.50.0/24 endpoint=10.0.0.9\\:51820",
  "peer=CCCC= allowed-ips=10.10.0.3/32",
].join("\n")
const m = M.parsePoll(mesh)
eq("mesh: three peers", m.peers.length, 3)
eq("mesh: hostname endpoint", m.peers[0].endpoint, "vpn.example.com:51820")
eq("mesh: peer with no endpoint", m.peers[2].endpoint, "")
eq("mesh: not full tunnel", M.isFullTunnel(m.peers), false)
eq("mesh: routes deduped+capped", M.routeSummary(m.peers), "10.10.0.1/32, 10.10.0.2/32, 192.168.50.0/24 +1")

// --- IPv6-only tunnel with a v6 default route ----------------------------
const v6 = [
  "known=1", "state=activated", "device=wg1",
  "address4=", "address6=fd86:ea04:1115::5/128,fe80::1234/64",
  "peer=DDDD= allowed-ips=\\:\\:/0 endpoint=[2001\\:db8\\:\\:1]\\:51820",
].join("\n")
const v = M.parsePoll(v6)
eq("v6: no v4", v.addresses4, [])
eq("v6: link-local filtered", v.addresses6, ["fd86:ea04:1115::5/128"])
eq("v6: ::/0 counts as full tunnel", M.isFullTunnel(v.peers), true)
eq("v6: bracketed endpoint", v.peers[0].endpoint, "[2001:db8::1]:51820")

// --- absent / broken profiles --------------------------------------------
eq("missing profile", M.parsePoll("known=0").known, false)
eq("empty input", M.parsePoll("").peers, [])
eq("no peers -> no route summary", M.routeSummary([]), "")

// --- formatting -----------------------------------------------------------
eq("bytes zero", M.formatBytes(0), "0 B")
eq("bytes MiB", M.formatBytes(7811891), "7.45 MiB")
eq("bytes negative -> dash", M.formatBytes(-1), "—")
eq("rate zero", M.formatRate(0), "0 bps")
eq("rate Kbps", M.formatRate(2125), "17 Kbps")
eq("rate negative -> dash", M.formatRate(-1), "—")
eq("shortKey truncates", M.shortKey("dqK72drYiE3NHgzrmx3U9LDTp0fOkQHi6qb19mX3FX4="), "dqK72drY…")

// --- profiles sharing one interface (full + split modes) ------------------
const modes = M.parsePoll([
  "known=1", "uuid=bbbb", "state=activated",
  "profile=aaaa\twg0", "profile=bbbb\twg0-split",
].join("\n"))
eq("modes: parsed", modes.profiles, [{ uuid: "aaaa", name: "wg0" }, { uuid: "bbbb", name: "wg0-split" }])
eq("modes: next wraps", M.nextProfile(modes.profiles, "bbbb").name, "wg0")
eq("modes: next forward", M.nextProfile(modes.profiles, "aaaa").name, "wg0-split")
eq("modes: three cycle", M.nextProfile([{uuid:"a"},{uuid:"b"},{uuid:"c"}], "b").uuid, "c")
eq("modes: single profile has no swap", M.nextProfile([{ uuid: "aaaa", name: "wg0" }], "aaaa"), null)
eq("modes: none listed", M.parsePoll("known=1").profiles, [])

console.log(failed ? `\n${failed} FAILED` : "\nall passed")
process.exit(failed ? 1 : 0)
