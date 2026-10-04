#!/usr/bin/env python3
"""Dashboard families, screenshots and process ownership, without a live ledger."""
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'template/scripts/dashboard.py'
SPEC = importlib.util.spec_from_file_location('dashboard_under_test', SOURCE)
dashboard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dashboard)


def check_families():
    raw = [
        {'id': 'epic', 'title': 'mixed', 'status': 'in_progress'},
        {'id': 'nested', 'title': 'nested', 'status': 'blocked', 'parent': 'epic'},
        {'id': 'ready', 'title': 'ready', 'status': 'open', 'dependencies': [
            {'depends_on_id': 'nested', 'type': 'parent-child'}]},
        {'id': 'blocked', 'title': 'blocked', 'status': 'blocked', 'parent': 'epic'},
        {'id': 'active', 'title': 'active', 'status': 'in_progress', 'parent': 'epic'},
        {'id': 'shelf', 'title': 'shelf', 'status': 'open', 'labels': ['backlog']},
        {'id': 'shelf2', 'title': 'shelf2', 'status': 'open', 'labels': ['backlog']},
        {'id': 'shelved', 'title': 'shelved', 'status': 'open', 'dependencies': [
            {'depends_on_id': 'shelf', 'type': 'parent-child'}]},
        {'id': 'unrelated', 'title': 'unrelated', 'status': 'open', 'dependencies': [
            {'depends_on_id': 'shelf', 'type': 'blocks'}]},
    ]
    with patch.object(dashboard, 'bd_json', return_value=raw), patch.object(dashboard, 'cached_stale', return_value=[]):
        payload = dashboard.ledger_state()
    by_id = {i['id']: i for i in payload['issues']}
    assert by_id['shelved']['backlog'] and not by_id['unrelated']['backlog']
    assert by_id['shelf']['children'] == ['shelved']
    assert by_id['ready']['parents'] == ['nested'] and not by_id['ready']['deps']
    # Membership fixtures supply ready flags independently of Beads blocking
    # inheritance: a parent may carry live work in several states at once.
    by_id['ready']['ready'] = True
    html = (ROOT / 'template/dashboard/index.html').read_text()
    script = html[html.index('      const $ ='):html.index('      /* ---- work tree', html.index('      const $ ='))]
    harness = '''
const assert = require('node:assert/strict')
const nodes = {}
global.document = {getElementById: id => nodes[id] ||= {}, addEventListener: () => {}, querySelectorAll: () => []}
global.window = {addEventListener: () => {}}
global.noLedger = false
global.worktree = {}
let rendered
'''
    checks = '''
paintBoard = rows => { rendered = Object.fromEntries(rows.map(r => [r.key, r.html])) }
const data = {ledger: payload, git: {unpushed_beads: [], unpushed: []}, worktree: []}
const ids = markup => [...(markup || '').matchAll(/data-bead="([^\"]+)"/g)].map(m => m[1])
const rows = key => ids(rendered[key])
drawBoard(data)
for (const key of ['ready', 'blocked', 'in_progress']) assert(rows(key).includes('epic'))
assert(!rows('ready').includes('ready'))
expandedEpics.add('epic'); expandedEpics.add('nested'); foldedLanes.add('blocked')
drawBoard(data)
assert.deepEqual(rows('ready'), ['epic', 'nested', 'ready'])
assert(rows('blocked').includes('blocked') && !rows('blocked').includes('ready'))
assert(rows('in_progress').includes('active') && !rows('in_progress').includes('ready'))
assert(!rendered.blocked.match(/data-lane="blocked"[^>]* open/))
for (const key of ['ready', 'blocked', 'in_progress']) assert.equal(new Set(rows(key)).size, rows(key).length)
const ready = ledger.byId.ready
ready.status = 'in_progress'; ready.ready = false
drawBoard(data)
assert(!rows('ready').includes('epic') && rows('in_progress').includes('ready'))
expandedEpics.delete('nested'); drawBoard(data)
assert(!rows('in_progress').includes('ready'))
expandedEpics.add('shelf'); drawBacklog(data)
assert.deepEqual(ids(nodes.backlogStrip.innerHTML), ['shelf', 'shelved', 'shelf2'])
ledger.byId.shelf.children = []
ledger.byId.shelf2.children = ['shelved']
ledger.byId.shelved.parent = 'shelf2'; ledger.byId.shelved.parents = ['shelf2']
drawBacklog(data)
assert.deepEqual(ids(nodes.backlogStrip.innerHTML), ['shelf', 'shelf2'])
expandedEpics.add('shelf2'); drawBacklog(data)
assert.deepEqual(ids(nodes.backlogStrip.innerHTML), ['shelf', 'shelf2', 'shelved'])
console.log('family membership, nesting, collapse, transitions and typed backlog repaint passed')
'''
    result = subprocess.run(['node', '-e', harness + script + '\nconst payload = ' + json.dumps(payload) + '\n' + checks], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    print(result.stdout.strip())
    return payload


def png(path, width, height, dark_pixels):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            pixels.extend(b'\0\0\0' if y * width + x < dark_pixels else b'\xff\xff\xff')
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))


def check_pixels(work):
    path = work / 'pixels.png'
    for width in (900, 360):
        png(path, width, 100, 0)
        assert 'blank' in dashboard.screenshot_problem(path)
        png(path, width, 100, width // 2)
        assert 'nearly blank' in dashboard.screenshot_problem(path)
        png(path, width, 100, width * 10)
        assert dashboard.screenshot_problem(path) is None
    path.write_bytes(b'not png')
    assert dashboard.screenshot_problem(path)
    # Check the capture path rejects unreadied pages and stale output, then
    # applies the same pixel check to a named state at narrow width.
    class StateResponse:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self): return b'{}'
    def capture(args, **kwargs):
        target = Path(next(a.split('=', 1)[1] for a in args if a.startswith('--screenshot=')))
        png(target, 360, 100, 0)
        return subprocess.CompletedProcess(args, 0, stdout='<html data-board-ready="true" data-shot-ready="staging">')
    with patch.object(dashboard, 'is_serving', return_value=True), patch.object(dashboard.urllib.request, 'urlopen', return_value=StateResponse()), patch.object(dashboard.subprocess, 'run', side_effect=capture):
        try:
            dashboard.shot(str(work / 'shot.png'), 1234, width=360, states=('staging',))
            raise AssertionError('blank capture accepted')
        except dashboard.ScreenshotError as e:
            assert 'invalid screenshot for staging' in str(e) and 'blank' in str(e)
        assert not (work / 'shot-staging.png').exists()
        with patch.object(sys, 'argv', ['dashboard.py', 'shot', str(work / 'shot.png'), 'staging', '--port', '1234']):
            try:
                dashboard.main()
                raise AssertionError('failed shot command exited successfully')
            except SystemExit as e:
                assert e.code and 'blank' in str(e.code)
    print('wide/narrow blank, near-blank and nonblank pixel checks passed')


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def read_identity(port):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/identity', timeout=1) as response:
        return json.load(response)


def check_ownership(work):
    ports = [free_port(), free_port()]
    processes, claims = [], []
    try:
        for number, port in enumerate(ports):
            root = work / str(number)
            root.mkdir()
            code = f'''
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('fixture', {str(SOURCE)!r})
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.ROOT = Path({str(root)!r})
m.prefix = lambda: {work.name!r}
m.state = lambda: {{'fixture': True}}
m.cached_peers = lambda: []
m.write_launch_config = lambda port: None
m.announce = lambda *args: None
sys.argv = ['dashboard.py', 'serve', '--port', {str(port)!r}]
m.main()
'''
            processes.append(subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            claims.append(Path(f'/tmp/{work.name}-dashboard-{port}.json'))
            deadline = time.monotonic() + 5
            while True:
                try:
                    identity = read_identity(port)
                    break
                except Exception:
                    assert time.monotonic() < deadline, 'fixture failed to bind'
                    time.sleep(.05)
            assert identity['root'] == str(root) and identity['pid'] == processes[-1].pid
        with patch.object(dashboard, 'ROOT', work / '0'):
            assert 'stopped' in dashboard.stop_serving()
        processes[0].wait(timeout=3)
        assert processes[1].poll() is None
        assert read_identity(ports[1])['root'] == str(work / '1')
        # A stale claim targeting this live fixture must never signal it when
        # the server's launch identity doesn't match the claimed owner/token.
        stale = work / 'stale'
        stale.mkdir()
        claims[1].write_text(json.dumps({'root': str(stale), 'pid': processes[1].pid, 'token': 'old'}))
        with patch.object(dashboard, 'ROOT', stale):
            assert 'refused' in dashboard.stop_serving()
        assert processes[1].poll() is None
        read_identity(ports[1])
        # Old boards lack the identity endpoint; refuse instead of trusting pid.
        class OldBoard(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(404); self.end_headers()
            def log_message(self, *args):
                pass
        with ThreadingHTTPServer(('127.0.0.1', 0), OldBoard) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            port = server.server_address[1]
            old_claim = Path(f'/tmp/{work.name}-dashboard-{port}.json')
            claims.append(old_claim)
            old_claim.write_text(json.dumps({'root': str(stale), 'pid': processes[1].pid}))
            with patch.object(dashboard, 'ROOT', stale):
                assert 'refused' in dashboard.stop_serving()
            assert processes[1].poll() is None
            server.shutdown()
        print('two-server isolation, stale identity and old-listener refusal passed')
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)
        for claim in claims:
            claim.unlink(missing_ok=True)


def main():
    (ROOT / '.tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='board-', dir=ROOT / '.tmp') as temporary:
        work = Path(temporary)
        payload = check_families()
        if '--fixture' in sys.argv:
            target = ROOT / '.tmp/board-fixture.json'
            target.write_text(json.dumps(payload, indent=2))
            print(target)
        check_pixels(work)
        check_ownership(work)


if __name__ == '__main__':
    main()
