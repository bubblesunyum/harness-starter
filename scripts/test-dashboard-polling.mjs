#!/usr/bin/env node
// Exercise the template page's actual polling/switch functions with delayed endpoints.
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

const page = readFileSync(new URL('../template/dashboard/index.html', import.meta.url), 'utf8')
const slice = (from, to) => page.slice(page.indexOf(from), page.indexOf(to, page.indexOf(from)))
const source =
  slice('      let peers = []', '      function drawMeta(d)') +
  slice('      /* Monotonic draw generation:', '      /* Pane placement') +
  slice('      async function switchPeer(peer)', "      document.addEventListener('click', (e) => {\n        const more")
const deferred = () => {
  let resolve
  const promise = new Promise((r) => { resolve = r })
  return {promise, resolve}
}
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
const response = (data) => ({json: async () => data})
const board = (root, n = 1) => ({root, project: root, generated: n})
const tabs = [{root: '/a', name: 'Board A'}, {root: '/b', name: 'Board B'}]
const nodes = new Map()
const timers = new Map()
const draws = []
const menus = []
const errors = []
let nextTimer = 0
let snapshot = board('/a')
let stateFetch = async () => response(snapshot)
let stateCalls = 0
let peerFetch
let peerCalls = 0
let switchCalls = 0
const context = vm.createContext({
  AbortController, Date, Promise, lastLedger: null,
  window: {addEventListener: () => {}},
  document: {querySelectorAll: () => [], documentElement: {setAttribute: () => {}}},
  $: (id) => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id) },
  esc: (s) => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;'),
  row: () => '', toast: (s) => errors.push(s),
  boardConfig: () => ({hidden: new Set(), order: []}),
  setTimeout: (fn, ms) => { const id = ++nextTimer; timers.set(id, {fn, ms}); return id },
  clearTimeout: (id) => timers.delete(id),
  draw: (d) => { draws.push(d); context.lastLedger = d },
  drawMeta: (d) => menus.push(d),
  fetch: (url, options) => {
    if (url.startsWith('state.json')) { stateCalls++; return stateFetch(options) }
    if (url === 'dashboards/switch') { switchCalls++; return Promise.resolve(response({ok: true})) }
    assert.ok(url.startsWith('dashboards?'))
    peerCalls++
    return peerFetch(options)
  },
})
vm.runInContext(source, context)
const inspect = (code) => vm.runInContext(code, context)

// A slow initial state remains eligible to paint after any number of interval
// ticks; those ticks do not invalidate or duplicate its request.
const initialState = deferred()
stateFetch = () => initialState.promise
const beforeInitial = stateCalls
const initialTick = context.tick()
await context.tick()
assert.equal(stateCalls, beforeInitial + 1)
initialState.resolve(response(board('/a')))
await initialTick
assert.equal(draws.at(-1).root, '/a', 'slow initial state is not starved by interval ticks')
stateFetch = async () => response(snapshot)
peerCalls = 0
menus.length = 0

// A state endpoint that never settles is timed out and releases single-flight
// ownership so the next interval can recover after the server returns.
stateFetch = () => new Promise(() => {})
const stalledStateTick = context.tick()
const stateDeadline = [...timers.values()].find((t) => t.ms === 10000)
assert.ok(stateDeadline, 'state polling has a bounded deadline')
stateDeadline.fn()
await stalledStateTick
assert.equal(inspect('statePoll'), null)
assert.equal(nodes.get('pulseLabel').textContent, 'offline')
stateFetch = async () => response(board('/a', 2))
await context.tick()
assert.equal(draws.at(-1).generated, 2, 'state polling recovers after a timeout')
peerCalls = 0
menus.length = 0

// A stalled optional endpoint cannot hold the first snapshot or its pulse.
const stalled = deferred()
peerFetch = () => stalled.promise
await context.tick()
assert.equal(draws.at(-1).root, '/a')
assert.equal(nodes.get('pulseLabel').textContent, 'live')
snapshot = board('/a', 2)
await context.tick()
assert.equal(draws.at(-1).generated, 2)
assert.equal(peerCalls, 1, 'peer discovery stays single-flight')
stalled.resolve(response({self: '/a', peers: tabs}))
await flush()
assert.equal(menus.length, 1, 'same-root peer metadata survives an ordinary newer state poll')
assert.equal(menus.at(-1).generated, 2, 'peer redraw uses the latest state snapshot')
assert.equal(inspect('peers.length'), 2)

// Even a fetch implementation that never settles after abort releases its slot.
let signal
peerFetch = (options) => { signal = options.signal; return new Promise(() => {}) }
await context.tick()
const deadline = [...timers.values()].find((t) => t.ms === 2000)
assert.ok(deadline, 'peer discovery has a deadline')
deadline.fn()
await flush()
assert.equal(signal.aborted, true)
assert.equal(inspect('peerPoll'), null)
assert.equal(nodes.get('pulseLabel').textContent, 'live')
peerFetch = async () => response({self: snapshot.root, peers: tabs})
await context.tick()
await flush()
assert.equal(inspect('peers.length'), 2)
assert.match(context.peerGroup(snapshot), /aria-checked="true" aria-disabled="true"[^>]*>Board A/)
assert.match(context.peerGroup(snapshot), /data-peer-root="\/b"/)
inspect('peers = [ {root: "/a", name: "Board A"}, {root: "/b", name: "Board B", switch_capable: false} ]')
assert.match(context.peerGroup(snapshot), /aria-disabled="true" data-peer-incapable="true" title="\/b — this board needs an update before it can switch">Board B/)
inspect('peers = [ {root: "/a", name: "Board A"}, {root: "/b", name: "Board B"} ]') // Older endpoints omit switch_capable; their peers stay usable.
assert.match(context.peerGroup(snapshot), /data-peer-root="\/b"/)
inspect('peers = [ {root: "/x", name: "Foreign", self: true}, {root: "/a", name: "Board A"} ]') // A listed entry carrying a self flag must not out-rank the endpoint root.
assert.match(context.peerGroup(snapshot), /data-peer-root="\/x"/)
inspect('peers = [ {root: "/a", name: "Board A"}, {root: "/b", name: "Board B"} ]')

// Older state fetches and peer metadata cannot paint over a checkout switch.
const oldPeers = deferred()
let oldPeerStarted = false
peerFetch = () => {
  if (oldPeerStarted) return Promise.resolve(response({self: snapshot.root, peers: tabs}))
  oldPeerStarted = true
  return oldPeers.promise
}
stateFetch = async () => response(snapshot)
await context.tick()
const oldState = deferred()
let oldSignal
stateFetch = (options) => { oldSignal = options.signal; return oldState.promise }
const oldTick = context.tick()
snapshot = board('/b', 3)
stateFetch = async () => response(snapshot)
const button = {dataset: {peerRoot: '/b'}, getAttribute: () => null, setAttribute: () => {}}
const switching = context.switchPeer(button)
await context.switchPeer(button)
await switching
assert.equal(oldSignal.aborted, true, 'switch cancels the previous state request')
oldState.resolve(response(board('/a', 0)))
oldPeers.resolve(response({self: '/a', peers: [{root: '/old', name: 'Old'}]}))
await oldTick
await flush()
assert.equal(switchCalls, 1, 'switching remains single-flight')
assert.equal(draws.at(-1).root, '/b')
assert.equal(inspect('startingPeerRoot'), '')
assert.equal(inspect('peers.some((p) => p.root === "/old")'), false)
assert.match(context.peerGroup(snapshot), /data-peer-root="\/a"/, 'switched board offers the way back')
assert.match(context.peerGroup(snapshot), /aria-checked="true" aria-disabled="true"[^>]*>Board B/)
peerFetch = async () => response({self: snapshot.root, peers: tabs})
snapshot = board('/a', 4)
await context.switchPeer({...button, dataset: {peerRoot: '/a'}})
await flush()
assert.equal(draws.at(-1).root, '/a', 'switching back repaints the original board')
assert.equal(errors.length, 0)

peerFetch = async () => response({self: '/a', peers: [{root: '', name: 'Invalid'}]})
await context.tick()
await flush()
assert.equal(inspect('peers.length'), 0, 'invalid peer payload falls back to the current board')
assert.match(context.peerGroup(snapshot), />\/a<\/button>/)
console.log('dashboard polling: delayed peers, timeout, stale responses, switch and way back passed')
