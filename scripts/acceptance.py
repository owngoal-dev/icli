#!/usr/bin/env python3
"""Device acceptance tests. Set ICLI_SSH_PASSWORD or use an SSH key.

The TestHost is a separate, test-only app and is not shipped in icli packages.
Results describe observed behavior; a command returning success is not an oracle.
"""
import argparse
import base64
import json
import os
import plistlib
import hashlib
from pathlib import Path
import shlex
import subprocess
import time
import uuid
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'dev.owngoal.icli.TestHost'
STATE = '/var/mobile/Library/Caches/icli-testhost/state.json'
CASES = []


def case(name, group, tools):
    def register(fn):
        CASES.append((name, group, tools, fn))
        return fn
    return register


class Device:
    def __init__(self):
        self.env = os.environ.copy()
        password = self.env.get('ICLI_SSH_PASSWORD')
        self.prefix = ['sshpass', '-e'] if password else []
        if password:
            self.env['SSHPASS'] = password
        self.host = self.env.get('ICLI_SSH_HOST', '127.0.0.1')
        self.port = self.env.get('ICLI_SSH_PORT', '2333')
        self.user = self.env.get('ICLI_SSH_USER', 'mobile')
        self.binary = self.env.get('ICLI_BINARY', '/var/jb/usr/bin/icli')
        self.options = ['-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new',
                        '-o', 'UserKnownHostsFile=' + str(ROOT / '.build/acceptance-known-hosts')]
        self.trace = []
        self.observations = []

    def run(self, command, timeout=35, sudo=False):
        command = shlex.join(command) if isinstance(command, list) else command
        password = self.env.get('ICLI_SSH_PASSWORD', '')
        if sudo:
            command = 'sudo -S -p "" ' + command
        start = time.monotonic()
        result = subprocess.run(self.prefix + ['ssh', '-p', self.port] + self.options +
                                [self.user + '@' + self.host, command],
                                env=self.env, input=(password + '\n') if sudo else None,
                                capture_output=True, text=True, timeout=timeout)
        trace = {'command': command, 'exit': result.returncode,
                           'seconds': round(time.monotonic()-start, 3),
                           'stdout': result.stdout[:12000], 'stderr': result.stderr[:2000]}
        self.trace.append(trace)
        result.icli_trace = trace
        return result

    def cli(self, *arguments, expected=0, timeout=35, sudo=False):
        result = self.run([self.binary] + list(arguments), timeout=timeout, sudo=sudo)
        result.icli_trace['cli_arguments'] = list(arguments)
        assert expected is None or result.returncode == expected, f'exit {result.returncode}, expected {expected}: {result.stdout[:1000]} {result.stderr[:500]}'
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError(f'not JSON: {result.stdout[:1000]}') from error

    def upload(self, local, remote):
        subprocess.run(self.prefix + ['scp', '-q', '-r', '-P', self.port] + self.options +
                       [str(local), self.user + '@' + self.host + ':' + remote], env=self.env, check=True)

    def state(self):
        result = self.run(['cat', STATE])
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def fixture(self, action='reset'):
        self.cli('app', 'launch', BUNDLE)
        time.sleep(0.3)
        self.cli('url', 'open', 'icli-test://' + action)
        time.sleep(0.3)

    def install(self):
        version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
        package = ROOT / f'.build/com.icli.icli_{version}_iphoneos-arm64.deb'
        subprocess.run([str(ROOT / 'packaging/build-deb.sh'), 'rootless'], cwd=ROOT, check=True)
        subprocess.run(self.prefix + ['scp', '-P', self.port] + self.options +
                       [str(package), self.user + '@' + self.host + ':/tmp/icli-acceptance.deb'], env=self.env, check=True)
        result = self.run(['dpkg', '-i', '/tmp/icli-acceptance.deb'], sudo=True)
        assert result.returncode == 0, result.stdout + result.stderr


@case('device_snapshot', 'runtime', ['device info', 'screen info'])
def device_snapshot(d):
    info = d.cli('device', 'info')
    assert info['jailbreak']['layout'] == 'rootless'
    assert info['memory_bytes'] > 0 and info['processor_count'] > 0
    screen = d.cli('screen', 'info')
    assert screen['width'] > 0 and screen['height'] > 0 and screen['scale'] >= 1


@case('file_roundtrip', 'runtime', ['fs write', 'fs read', 'fs ls'])
def files(d):
    path = '/tmp/icli-acceptance'
    d.cli('fs', 'write', path+'/text.txt', 'icli 中文 🌱\nsecond line')
    assert d.cli('fs', 'read', path+'/text.txt')['content'] == 'icli 中文 🌱\nsecond line'
    data = bytes(range(256))
    encoded = base64.b64encode(data).decode()
    d.cli('fs', 'write', path+'/binary.bin', encoded, '--encoding', 'base64')
    assert base64.b64decode(d.cli('fs', 'read', path+'/binary.bin', '--binary')['content']) == data
    assert d.cli('fs', 'read', path+'/binary.bin', '--limit', '8')['truncated']
    assert {entry['name'] for entry in d.cli('fs', 'ls', path)['entries']} >= {'text.txt', 'binary.bin'}
    d.cli('fs', 'read', path+'/missing', expected=1)
    d.cli('fs', 'write', path+'/bad.bin', '%%%invalid', '--encoding', 'base64', expected=1)
    d.cli('fs', 'read', path+'/text.txt', '--limit=-1', expected=1)
    d.cli('fs', 'write', path+'/bad.txt', 'text', '--encoding', 'unknown', expected=1)


@case('ax_tree_and_tap', 'ax', ['ui tree', 'ui tap'])
def ax_tree(d):
    d.fixture()
    # Cold launching TestHost after installation can precede AX registration.
    deadline = time.monotonic() + 5
    while True:
        ready = d.cli('ui', 'tree', expected=None)
        if any(e.get('identifier') == 'counter.increment' for e in ready.get('elements', [])):
            break
        assert time.monotonic() < deadline, 'TestHost accessibility did not become ready: ' + str(ready)
        time.sleep(0.3)
    tree = d.cli('ui', 'tree')
    assert tree['source'] == 'ax' and tree['count'] > 3
    assert any(e.get('label') == 'Increment' for e in tree['elements'])
    d.cli('ui', 'tap', 'Increment', '--match', 'exact')
    time.sleep(0.2)
    assert d.state()['counter'] == 1
    d.cli('ui', 'tap', 'no-such-element', expected=1)


@case('ax_identifier', 'ax', ['ui tap'])
def ax_identifier(d):
    d.fixture()
    d.cli('ui', 'tap', '--identifier', 'counter.increment')
    time.sleep(0.2)
    assert d.state()['counter'] == 1


@case('ax_hit_test', 'ax', ['ui at'])
def ax_hit(d):
    d.fixture()
    hit = d.cli('ui', 'at', '100', '245')
    assert hit['element']['label'] == 'Increment'
    d.cli('ui', 'at', '--', '-1', '245', expected=1)


@case('ax_waits', 'ax', ['ui wait', 'ui wait-gone'])
def ax_waits(d):
    d.fixture()
    d.cli('url', 'open', 'icli-test://toggle')
    result = d.cli('ui', 'wait', 'Ready element', '--timeout', '4')
    assert result['found'] and d.state()['delayed_visible']
    d.cli('url', 'open', 'icli-test://toggle')
    result = d.cli('ui', 'wait-gone', 'Ready element', '--timeout', '4')
    assert result['disappeared'] and not d.state()['delayed_visible']
    d.cli('ui', 'wait', 'Never appears', '--timeout', '0.2', expected=1)


@case('touch_tap', 'gestures', ['screen tap'])
def touch_tap(d):
    d.fixture()
    d.cli('screen', 'tap', '100', '245')
    time.sleep(0.2)
    assert d.state()['counter'] == 1


@case('touch_double_and_long', 'gestures', ['screen double-tap', 'screen long-press'])
def touch_double(d):
    d.fixture()
    d.cli('screen', 'double-tap', '150', '390')
    time.sleep(0.2)
    assert d.state().get('double_taps') == 1
    d.cli('screen', 'long-press', '150', '390', '--seconds', '0.6')
    time.sleep(0.2)
    assert d.state().get('long_presses') == 1


@case('touch_swipe', 'gestures', ['screen swipe'])
def touch_swipe(d):
    d.fixture()
    d.cli('screen', 'swipe', '--from-x', '180', '--from-y', '625', '--to-x', '180', '--to-y', '560', '--seconds', '0.4')
    time.sleep(0.3)
    assert d.state().get('scroll_y', 0) > 20


@case('touch_drag_path', 'gestures', ['screen drag'])
def touch_drag(d):
    d.fixture()
    d.cli('screen', 'drag', '--points', '[{"x":54,"y":500},{"x":140,"y":480},{"x":240,"y":500}]', '--hold', '0.5', '--seconds', '0.6', '--steps', '30')
    time.sleep(0.3)
    state = d.state()
    assert state.get('drag_events', 0) > 3 and state['drag_x'] > 180


@case('unicode_input', 'input', ['input paste', 'input type', 'input key'])
def unicode_input(d):
    d.fixture('reset')
    d.cli('url', 'open', 'icli-test://focus')
    time.sleep(0.4)
    text = 'AbC 123 !@# 中文 🌱'
    d.cli('input', 'paste', text)
    time.sleep(0.3)
    assert d.state()['text'] == text, d.state()
    d.cli('input', 'key', 'cmd+a')
    d.cli('input', 'key', 'backspace')
    time.sleep(0.2)
    assert d.state()['text'] == ''
    d.cli('input', 'type', 'XyZ!? 中文', '--delay-ms', '20')
    time.sleep(0.3)
    assert d.state()['text'] == 'XyZ!? 中文', d.state()
    d.cli('input', 'key', 'enter')
    time.sleep(0.2)
    assert d.state()['text'].endswith('\n')
    d.cli('url', 'open', 'icli-test://blur')


@case('clipboard_roundtrip', 'input', ['clipboard get', 'clipboard set'])
def clipboard(d):
    d.fixture('clipboard-set')
    assert d.cli('clipboard', 'get')['text'] == 'TestHost clipboard 中文 🌱'
    assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE
    for text in ['clipboard 中文 🌱', '']:
        d.cli('clipboard', 'set', text)
        assert d.cli('clipboard', 'get')['text'] == text
        assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE
        time.sleep(0.3)
        d.fixture()
        d.cli('url', 'open', 'icli-test://focus')
        time.sleep(0.4)
        d.cli('input', 'key', 'cmd+v')
        time.sleep(0.3)
        assert d.state()['text'] == text
        d.cli('url', 'open', 'icli-test://blur')


@case('app_lifecycle_and_metadata', 'apps', ['app list', 'app launch', 'app kill', 'app running', 'app frontmost', 'app info', 'url open'])
def app_lifecycle(d):
    assert any(a['bundle_id'] == BUNDLE for a in d.cli('app', 'list')['apps'])
    d.fixture()
    assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE
    assert any(a['bundle_id'] == BUNDLE and a['pid'] > 0 for a in d.cli('app', 'running')['apps'])
    info = d.cli('app', 'info', BUNDLE)
    assert info['entitlements']['application-identifier'] == BUNDLE, info
    assert info['encrypted'] is False and info['executable'].endswith('IcliTestHost')
    d.cli('app', 'kill', BUNDLE, '--force')
    assert all(a['bundle_id'] != BUNDLE for a in d.cli('app', 'running')['apps'])
    assert d.cli('app', 'kill', BUNDLE, '--force')['already_stopped']
    d.cli('app', 'launch', BUNDLE)
    d.cli('app', 'launch', 'icli.nonexistent.app', expected=1)
    d.cli('url', 'open', 'icli-test://reset')
    assert d.state()['last_url'] == 'icli-test://reset'


@case('brightness_and_volume', 'controls', ['device brightness get', 'device brightness set', 'device volume get', 'device volume set'])
def brightness_volume(d):
    d.fixture()
    original_b = d.cli('device', 'brightness', 'get')['brightness']
    original_v = d.cli('device', 'volume', 'get')['volume']
    try:
        for value in [0.25, 0.65]:
            d.cli('device', 'brightness', 'set', str(value))
            assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE
            time.sleep(0.2)
            assert abs(d.cli('device', 'brightness', 'get')['brightness']-value) < 0.03
            d.cli('device', 'volume', 'set', str(value))
            time.sleep(0.2)
            assert abs(d.cli('device', 'volume', 'get')['volume']-value) < 0.03
        d.cli('device', 'brightness', 'set', '1.1', expected=1)
        d.cli('device', 'volume', 'set', 'nan', expected=1)
    finally:
        d.cli('device', 'brightness', 'set', str(original_b))
        d.cli('device', 'volume', 'set', str(original_v))


@case('install_remove_deb', 'install', ['app install', 'app uninstall'])
def install_deb(d):
    package = '/tmp/icli-install-fixture.deb'
    marker = '/var/mobile/Library/Caches/icli-install-test/marker.txt'
    d.cli('app', 'install', package, sudo=True)
    assert d.cli('fs', 'read', marker)['content'] == 'icli installation verified\n'
    d.cli('app', 'uninstall', 'dev.owngoal.icli.installtest', '--package', '--force', sudo=True)
    d.cli('fs', 'read', marker, expected=1)
    d.cli('app', 'install', '/tmp/icli-no-such-package.deb', expected=1)


@case('install_remove_ipa', 'install', ['app install', 'app uninstall'])
def install_ipa(d):
    bundle = 'dev.owngoal.icli.InstallFixture'
    d.cli('app', 'install', '/tmp/icli-install-fixture.ipa', timeout=150, sudo=True)
    assert d.cli('app', 'info', bundle)['bundle_id'] == bundle
    d.cli('app', 'launch', bundle)
    upgraded = d.cli('app', 'install', '/tmp/icli-install-fixture.ipa', timeout=150, sudo=True)
    assert upgraded['upgraded'], upgraded
    d.cli('app', 'launch', bundle)
    d.cli('app', 'uninstall', bundle, '--force', sudo=True)
    d.cli('app', 'info', bundle, expected=1)
    d.fixture()


@case('crash_report_roundtrip', 'logs', ['log crashes', 'log crash'])
def crash_report(d):
    d.fixture()
    old = set(d.cli('log', 'crashes', '--bundle-id', BUNDLE)['crashes'])
    d.cli('url', 'open', 'icli-test://crash')
    deadline = time.monotonic() + 35
    found = set()
    while time.monotonic() < deadline:
        found = set(d.cli('log', 'crashes', '--bundle-id', BUNDLE)['crashes']) - old
        if found:
            break
        time.sleep(1)
    assert found, 'no new TestHost crash report'
    report = d.cli('log', 'crash', sorted(found)[0])
    assert not report['truncated'] and 'IcliTestHost' in report['content']
    d.cli('log', 'crash', '/tmp/icli-missing.ips', expected=1)
    d.fixture()


@case('home_power_wake', 'controls', ['button home', 'button power', 'button wake'])
def home_power(d):
    d.fixture()

    d.cli('button', 'home')
    time.sleep(0.4)
    assert d.cli('app', 'frontmost')['bundle_id'] == 'com.apple.springboard'
    d.cli('button', 'power')
    time.sleep(0.4)
    try:
        assert d.cli('screen', 'info')['screen_off']
        d.cli('screen', 'tap', '100', '245', expected=2)
        assert d.cli('screen', 'shot', '--base64')['data']
    finally:
        d.cli('button', 'wake')
    time.sleep(0.4)
    info = d.cli('screen', 'info')
    assert not info['screen_off'] and not info['locked'], info
    d.fixture()


@case('audio_buttons', 'controls', ['button volume-up', 'button volume-down', 'button mute'])
def audio_buttons(d):
    d.fixture('audio-start')
    assert d.state()['audio_playing']
    original = d.cli('device', 'volume', 'get')
    d.cli('device', 'volume', 'set', '0.5')
    try:
        d.cli('button', 'volume-up')
        increased = d.cli('device', 'volume', 'get')['active_volume']
        assert increased > 0.5, increased
        d.cli('button', 'volume-down')
        assert d.cli('device', 'volume', 'get')['active_volume'] < increased
        before = d.cli('device', 'volume', 'get')['active_muted']
        d.cli('button', 'mute')
        assert d.cli('device', 'volume', 'get')['active_muted'] != before
        d.cli('button', 'mute')
        assert d.cli('device', 'volume', 'get')['active_muted'] == before
    finally:
        d.cli('device', 'volume', 'set', str(original['volume']))
        d.cli('url', 'open', 'icli-test://audio-stop')


@case('screenshot_coordinates', 'screen', ['screen shot', 'screen info'])
def screenshot(d):
    d.fixture()
    info = d.cli('screen', 'info')
    shot = d.cli('screen', 'shot', '--base64')
    data = base64.b64decode(shot['data'])
    assert data.startswith(b'\xff\xd8') and data.endswith(b'\xff\xd9')
    assert shot['width'] == info['width'] and shot['height'] == info['height'] and shot['coordinate_scale'] == 1
    assert shot['bytes'] == len(data)
    (ROOT / '.build/testhost.jpg').write_bytes(data)


@case('raster_ocr_and_description', 'screen', ['screen ocr', 'screen describe'])
def raster_ocr(d):
    d.fixture()
    result = d.cli('screen', 'ocr', expected=None)
    described = d.cli('screen', 'describe')
    assert described['frontmost']['bundle_id'] == BUNDLE
    assert described['elements']['source'] == 'ax'
    if 'error' in result:
        assert result['error'] == 'unavailable' and result['message'], result
        assert described['ocr']['error'] == 'unavailable', described['ocr']
        d.cli('url', 'open', 'icli-test://ocr')
        oracle = d.state()['ocr']
        assert not oracle['ok'] and oracle['error'], oracle
        d.observations.append('System Vision OCR is unavailable; direct OCR and screen description report it explicitly, independently confirmed by TestHost.')
    else:
        assert result['engine'] == 'vision'
        for text, expected_y in [('HELLO 123', 691), ('中文测试', 726)]:
            block = next(b for b in result['blocks'] if b['text'] == text)
            assert abs(block['y']-expected_y) < 15 and block['confidence'] > 0.7, block
        assert any(b['text'] == '中文测试' for b in described['ocr']['blocks'])
    assert not described['context_changed']
    assert base64.b64decode(described['screenshot']['data']).startswith(b'\xff\xd8')
    d.cli('screen', 'ocr', '--min-confidence', '2', expected=1)


@case('invalid_gesture_parameters', 'gestures', ['screen tap', 'screen swipe', 'screen drag', 'screen long-press', 'screen double-tap'])
def invalid_gestures(d):
    d.cli('screen', 'tap', 'nan', '10', expected=1)
    d.cli('screen', 'tap', '99999', '10', expected=1)
    d.cli('screen', 'long-press', '10', '10', '--seconds', '0', expected=1)
    d.cli('screen', 'double-tap', '10', '10', '--interval', 'nan', expected=1)
    d.cli('screen', 'drag', '--points', '[{"x":10}]', expected=1)
    d.cli('screen', 'swipe', '--from-x', '10', '--from-y', '10', '--to-x', '20', '--to-y', '20', '--seconds', '0', expected=1)


@case('unified_log_events', 'logs', ['log syslog'])
def unified_log(d):
    d.fixture()
    result = d.cli('log', 'syslog', '--seconds', '3', '--process', 'IcliTestHost', '--level', 'error')
    assert result['source'] == 'unified_log'
    assert any('icli-testhost-heartbeat' in event['message'] for event in result['entries']), result
    assert all(event['level'] in ['error', 'fault'] for event in result['entries'])



@case('extended_files', 'runtime', ['fs find', 'fs plist'])
def extended_files(d):
    path = '/tmp/icli-acceptance/sample.plist'
    xml = plistlib.dumps({'name': 'icli', 'count': 3}).decode()
    d.cli('fs', 'write', path, xml)
    assert path in d.cli('fs', 'find', '/tmp/icli-acceptance', '.plist')['matches']
    assert d.cli('fs', 'plist', path)['plist'] == {'name': 'icli', 'count': 3}


@case('filesystem_maintenance', 'runtime', ['fs mkdir', 'fs rm', 'fs link', 'fs chmod', 'fs chown', 'fs copy', 'fs move', 'fs plist-set'])
def filesystem_maintenance(d):
    folder = '/tmp/icli-fs-' + uuid.uuid4().hex
    source, copied, moved, link = [folder + '/' + name for name in ['source', 'copied', 'moved', 'link']]
    try:
        assert d.cli('fs', 'mkdir', folder, '--mode', '750')['created']
        assert d.run(['stat', '-c', '%a', folder]).stdout.strip() == '750'
        assert not d.cli('fs', 'mkdir', folder)['created']
        d.cli('fs', 'write', source, 'filesystem fixture 中文')
        d.cli('fs', 'copy', source, copied)
        assert d.run(['cmp', source, copied]).returncode == 0
        d.cli('fs', 'copy', source, copied, expected=1)
        d.cli('fs', 'move', copied, moved)
        assert d.run(['test', '-e', copied]).returncode == 1
        assert d.run(['cat', moved]).stdout == 'filesystem fixture 中文'
        d.cli('fs', 'link', source, link)
        assert d.run(['readlink', link]).stdout.strip() == source
        d.cli('fs', 'link', moved, link, expected=1)
        d.cli('fs', 'link', moved, link, '--replace')
        assert d.run(['readlink', link]).stdout.strip() == moved
        d.cli('fs', 'chmod', source, '640')
        assert d.run(['stat', '-c', '%a', source]).stdout.strip() == '640'
        d.cli('fs', 'chmod', source, '888', expected=1)
        d.cli('fs', 'chown', source, '0:0', sudo=True)
        assert d.run(['stat', '-c', '%u:%g', source]).stdout.strip() == '0:0'
        d.cli('fs', 'chown', source, 'mobile:mobile', sudo=True)
        assert d.run(['stat', '-c', '%u:%g', source]).stdout.strip() == '501:501'
        for format in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
            path = folder + '/settings.plist'
            body = plistlib.dumps({'keep': ['original'], 'flag': False}, fmt=format)
            d.cli('fs', 'write', path, base64.b64encode(body).decode(), '--encoding', 'base64')
            d.cli('fs', 'plist-set', path, 'flag', 'true')
            d.cli('fs', 'plist-set', path, 'count', '42')
            d.cli('fs', 'plist-set', path, 'flag', '--remove')
            actual = base64.b64decode(d.cli('fs', 'read', path, '--binary')['content'])
            assert plistlib.loads(actual) == {'keep': ['original'], 'count': 42}
            assert actual.startswith(b'bplist00') == (format == plistlib.FMT_BINARY)
            d.cli('fs', 'plist-set', path, 'count', 'invalid-json', expected=1)
            assert base64.b64decode(d.cli('fs', 'read', path, '--binary')['content']) == actual
        d.cli('fs', 'rm', source, expected=1)
        assert d.run(['test', '-f', source]).returncode == 0
        d.cli('fs', 'rm', folder, '--force', expected=1)
        d.cli('fs', 'rm', link, '--force')
        assert d.run(['test', '-f', moved]).returncode == 0
        d.cli('fs', 'rm', folder, '--recursive', '--force')
        assert d.run(['test', '-e', folder]).returncode == 1
        assert not d.cli('fs', 'rm', folder, '--force')['removed']
    finally:
        assert d.run(['rm', '-rf', folder], sudo=True).returncode == 0


@case('extended_app_metadata', 'apps', ['app search', 'app open', 'app handlers', 'app schemes', 'app binary', 'app data', 'proc list'])
def extended_apps(d):
    d.fixture()
    assert any(a['bundle_id'] == BUNDLE for a in d.cli('app', 'search', 'TestHost')['apps'])
    d.cli('app', 'open', 'icli-test://reset', '--bundle', BUNDLE)
    time.sleep(0.3)
    assert d.state()['last_url'] == 'icli-test://reset'
    handlers = d.cli('app', 'handlers', 'icli-test://reset')
    assert BUNDLE in json.dumps(handlers), handlers
    assert 'icli-test' in d.cli('app', 'schemes')['schemes'][BUNDLE]
    binary = d.cli('app', 'binary', BUNDLE)
    assert binary['encrypted'] is False and binary['executable'].endswith('IcliTestHost'), binary
    data = d.cli('app', 'data', BUNDLE)
    assert data['bundle_id'] == BUNDLE, data
    processes = d.cli('proc', 'list', '--filter', 'IcliTestHost')['processes']
    assert any(p['pid'] > 0 and p['name'] == 'IcliTestHost' for p in processes)


@case('rotation_and_lock', 'controls', ['device rotation get', 'device rotation set', 'device rotation lock get', 'device rotation lock set'])
def rotation(d):
    d.fixture()
    original = d.cli('device', 'rotation', 'get')
    try:
        d.cli('device', 'rotation', 'lock', 'set', 'off')
        assert d.cli('device', 'rotation', 'lock', 'get')['locked'] is False
        for value, degrees in [('landscape-left', 90), ('portrait', 0)]:
            d.cli('device', 'rotation', 'set', value)
            time.sleep(0.5)
            assert d.cli('device', 'rotation', 'get')['degrees'] == degrees
        d.cli('device', 'rotation', 'lock', 'set', 'on')
        assert d.cli('device', 'rotation', 'lock', 'get')['locked'] is True
        d.cli('device', 'rotation', 'set', 'diagonal', expected=1)
        d.cli('device', 'rotation', 'lock', 'set', 'invalid', expected=1)
    finally:
        d.cli('device', 'rotation', 'lock', 'set', 'off')
        d.cli('device', 'rotation', 'set', str(original['degrees']))
        d.cli('device', 'rotation', 'lock', 'set', 'on' if original['locked'] else 'off')


@case('package_commands', 'packages', ['pkg list', 'pkg install', 'pkg remove', 'pkg tweaks', 'pkg status'])
def packages(d):
    name = 'dev.owngoal.icli.installtest'
    marker = '/var/mobile/Library/Caches/icli-install-test/marker.txt'
    assert d.cli('pkg', 'status', name)['installed'] is False
    try:
        installed = d.cli('pkg', 'install', '/tmp/icli-install-fixture.deb', sudo=True, timeout=150)
        assert installed['result'] == 'installed' and installed['version'] == '1.0', installed
        status = d.cli('pkg', 'status', name)
        assert status['installed'] and status['version'] == '1.0' and status['status'] == 'install ok installed', status
        assert any(p['package'] == name for p in d.cli('pkg', 'list', '--filter', name)['packages'])
        assert d.cli('fs', 'read', marker)['content'] == 'icli installation verified\n'
        # Same version again: the transaction runs but nothing changes (PKG-02 reinstall).
        again = d.cli('pkg', 'install', '/tmp/icli-install-fixture.deb', sudo=True, timeout=150)
        assert again['result'] == 'reinstalled' and again['previous_version'] == '1.0', again
    finally:
        removed = d.cli('pkg', 'remove', name, sudo=True)
    assert removed['removed'] is True and removed['previous_version'] == '1.0', removed
    assert d.cli('pkg', 'remove', name, sudo=True)['removed'] is False
    assert d.cli('pkg', 'status', name)['installed'] is False
    d.cli('fs', 'read', marker, expected=1)
    d.cli('pkg', 'install', '/tmp/icli-no-such-package.deb', sudo=True, expected=1)
    assert 'error' in d.cli('pkg', 'install', 'icli.no.such.package', sudo=True, expected=None)
    d.cli('pkg', 'status', 'Bad Name', expected=1)
    assert isinstance(d.cli('pkg', 'tweaks')['tweaks'], list)


@case('package_metadata_native', 'packages', ['pkg info', 'pkg extract', 'pkg compare'])
def package_metadata(d):
    info = d.cli('pkg', 'info', '/tmp/icli-install-fixture.deb')
    assert info['control']['Package'] == 'dev.owngoal.icli.installtest' and info['control']['Version'] == '1.0', info
    assert info['format'] == '2.0' and info['data_member'].startswith('data.tar') and info['extracted'] is False
    assert any(f['path'].endswith('icli-install-test/marker.txt') and f['type'] == 'file' for f in info['files']), info['files']
    stage = '/tmp/icli-extract-' + uuid.uuid4().hex
    try:
        extracted = d.cli('pkg', 'extract', '/tmp/icli-install-fixture.deb', stage)
        assert extracted['extracted'] is True
        assert d.cli('fs', 'read', stage + '/var/mobile/Library/Caches/icli-install-test/marker.txt')['content'] == 'icli installation verified\n'
        assert 'Package: dev.owngoal.icli.installtest' in d.cli('fs', 'read', stage + '/DEBIAN/control')['content']
        d.cli('pkg', 'extract', '/tmp/icli-install-fixture.deb', stage, expected=1)
    finally:
        d.run(['rm', '-rf', stage])
    d.cli('pkg', 'info', '/tmp/icli-no-such-package.deb', expected=1)
    d.cli('pkg', 'info', '/tmp/icli-install-fixture.ipa', expected=1)
    for left, right, relation in [('1.0', '1:0.9', 'lt'), ('1.0~beta', '1.0', 'lt'), ('2.0.6', '0:2.0.6:compat', 'lt'), ('1.0-2', '1.0-1', 'gt'), ('1.0', '1.0', 'eq')]:
        assert d.cli('pkg', 'compare', left, right)['relation'] == relation, (left, right)
    d.cli('pkg', 'compare', 'not a version', '1', expected=1)


@case('launchd_services', 'system', ['svc load', 'svc unload', 'svc enable', 'svc disable', 'svc status'])
def launchd_services(d):
    label = 'dev.owngoal.icli.testdaemon'
    plist = f'/var/jb/Library/LaunchDaemons/{label}.plist'
    folder = '/tmp/icli-daemons-' + uuid.uuid4().hex
    body = plistlib.dumps({'Label': label, 'ProgramArguments': ['/var/jb/usr/bin/sleep', '3600'], 'KeepAlive': True, 'RunAtLoad': True}).decode()
    initial = d.cli('svc', 'status', label)
    assert initial['enabled'] and not initial['loaded'] and not initial['running'], initial
    d.cli('svc', 'status', 'bad label!', expected=1)
    d.cli('svc', 'load', '/tmp/icli-no-such-daemon.plist', sudo=True, expected=1)
    d.cli('fs', 'write', '/tmp/icli-daemon.plist', body)
    assert d.run(['sh', '-c', f'cp /tmp/icli-daemon.plist {plist} && chown root:wheel {plist} && chmod 644 {plist} && mkdir -p {folder} && cp {plist} {folder}/'], sudo=True).returncode == 0
    try:
        loaded = d.cli('svc', 'load', plist, sudo=True)
        assert loaded['verified'] and loaded['services'][0]['label'] == label, loaded
        time.sleep(1)
        status = d.cli('svc', 'status', label)
        assert status['loaded'] and status['running'] and status['pid'] > 0 and status['program'] == '/var/jb/usr/bin/sleep', status
        assert any(p['pid'] == status['pid'] for p in d.cli('proc', 'list', '--filter', 'sleep')['processes']), 'launchd pid is not a live process'
        assert d.cli('svc', 'load', plist, sudo=True)['unchanged'] is True
        assert d.cli('svc', 'disable', label, sudo=True)['changed'] is True
        disabled = d.cli('svc', 'status', label)
        assert disabled['enabled'] is False and disabled['override'] is True, disabled
        assert d.cli('svc', 'disable', label, sudo=True)['changed'] is False
        assert d.cli('svc', 'enable', label, sudo=True)['changed'] is True
        assert d.cli('svc', 'status', label)['enabled'] is True
        d.cli('svc', 'disable', label, expected=1)
        unloaded = d.cli('svc', 'unload', plist, sudo=True)
        assert unloaded['verified'] and unloaded['services'][0]['loaded'] is False, unloaded
        time.sleep(0.5)
        after = d.cli('svc', 'status', label)
        assert not after['loaded'] and not after['running'], after
        assert all(p['pid'] != status['pid'] for p in d.cli('proc', 'list', '--filter', 'sleep')['processes']), 'daemon process survived unload'
        assert d.cli('svc', 'unload', plist, sudo=True)['unchanged'] is True
        # SVC-03: a directory of daemons loads in one request.
        batch = d.cli('svc', 'load', folder, sudo=True)
        assert batch['verified'] and batch['services'][0]['path'] == f'{folder}/{label}.plist', batch
        time.sleep(1)
        assert d.cli('svc', 'status', label)['running'] is True
        assert d.cli('svc', 'unload', folder, sudo=True)['verified'] is True
    finally:
        d.cli('svc', 'unload', plist, sudo=True, expected=None)
        d.run(['rm', '-rf', plist, folder, '/tmp/icli-daemon.plist'], sudo=True)
    assert d.cli('svc', 'status', label)['loaded'] is False


@case('app_registration_refresh', 'apps', ['app refresh', 'app unregister-dir', 'app register', 'app unregister'])
def app_refresh(d):
    bundle = 'dev.owngoal.icli.InstallFixture'
    folder = '/tmp/icli-apps-' + uuid.uuid4().hex
    app = folder + '/IcliInstallFixture.app'
    assert d.run(['mkdir', '-p', folder]).returncode == 0
    d.upload(ROOT / '.build/install-fixtures/Payload/IcliInstallFixture.app', app)
    try:
        # APP-01: registration is proven by LaunchServices listing the bundle at that path.
        registered = d.cli('app', 'register', app)
        assert registered['registered'] and registered['bundle_id'] == bundle, registered
        assert d.cli('app', 'info', bundle)['bundle_path'].endswith('/IcliInstallFixture.app')
        d.cli('app', 'register', folder + '/missing.app', expected=1)
        # APP-03: refresh re-registers the directory, then drops the entry once its bundle vanished.
        refreshed = d.cli('app', 'refresh', '--directory', folder)
        assert refreshed['registered'] == [app.replace('/tmp/', '/var/tmp/')] and not refreshed['failed'] and not refreshed['unverified'], refreshed
        d.run(['rm', '-rf', app])
        refreshed = d.cli('app', 'refresh', '--directory', folder)
        assert refreshed['registered'] == [] and len(refreshed['unregistered']) == 1 and not refreshed['unverified'], refreshed
        d.cli('app', 'info', bundle, expected=1)
        d.cli('app', 'refresh', '--directory', folder + '/nonexistent', expected=1)
        d.upload(ROOT / '.build/install-fixtures/Payload/IcliInstallFixture.app', app)
        assert d.cli('app', 'refresh', '--directory', folder)['registered'] == [app.replace('/tmp/', '/var/tmp/')]
        # APP-04: batch unregistration of everything directly in a directory.
        d.cli('app', 'unregister-dir', folder, expected=1)
        removed = d.cli('app', 'unregister-dir', folder, '--force')
        assert removed['unregistered'] and not removed['failed'] and not removed['unverified'], removed
        d.cli('app', 'info', bundle, expected=1)
        assert d.cli('app', 'unregister', app, '--force')['unregistered'] is False
        # APP-02 on the bootstrap's own app directory, as root, restored by refresh.
        path = '/var/jb/Applications/IcliTestHost.app'
        d.cli('app', 'unregister', path, expected=1)
        assert d.cli('app', 'unregister', path, '--force', sudo=True)['unregistered'] is True
        assert BUNDLE not in json.dumps(d.cli('app', 'handlers', 'icli-test://reset'))
    finally:
        d.cli('app', 'unregister-dir', folder, '--force', expected=None)
        d.run(['rm', '-rf', folder])
        restored = d.cli('sb', 'uicache', sudo=True, timeout=90)
    assert any(p.endswith('/IcliTestHost.app') for p in restored['registered']) and not restored['failed'], restored
    assert BUNDLE in json.dumps(d.cli('app', 'handlers', 'icli-test://reset'))
    d.fixture()


@case('app_network_policy', 'apps', ['app network get', 'app network repair'])
def app_network(d):
    before = d.cli('app', 'network', 'get', BUNDLE)
    assert before['bundle_id'] == BUNDLE and isinstance(before['allowed'], bool) and 'kCTWiFiDataUsagePolicy' in before['policy'], before
    repaired = d.cli('app', 'network', 'repair', BUNDLE, sudo=True)
    assert repaired['allowed'] is True and repaired['changed'] == (not before['allowed']), repaired
    after = d.cli('app', 'network', 'get', BUNDLE)
    assert after['policy']['kCTCellularDataUsagePolicy'] == 'kCTCellularDataUsagePolicyAlwaysAllow'
    assert after['policy']['kCTWiFiDataUsagePolicy'] == 'kCTCellularDataUsagePolicyAlwaysAllow'
    d.cli('app', 'network', 'get', 'not a bundle id', expected=1)
    d.fixture()
    d.cli('url', 'open', 'icli-test://network-probe')
    assert d.state()['network_bytes'] > 0, 'TestHost could not use the network after the repair'


@case('system_apps_visibility', 'system', ['sb system-apps get', 'sb system-apps set'])
def system_apps(d):
    original = d.cli('sb', 'system-apps', 'get')
    assert isinstance(original['visible'], bool) and isinstance(original['configured'], bool)
    flipped = not original['visible']
    try:
        changed = d.cli('sb', 'system-apps', 'set', 'on' if flipped else 'off', sudo=True)
        assert changed['changed'] and changed['visible'] is flipped and changed['requires_respring'], changed
        assert d.cli('sb', 'system-apps', 'get')['visible'] is flipped
        assert d.cli('sb', 'system-apps', 'set', 'on' if flipped else 'off', sudo=True)['changed'] is False
        # cfprefsd acknowledges synchronization before its disk flush finishes.
        deadline = time.monotonic() + 15
        while True:
            stored = d.cli('fs', 'plist', '/var/mobile/Library/Preferences/com.apple.springboard.plist', sudo=True)
            if stored['plist'].get('SBShowNonDefaultSystemApps') is flipped:
                break
            assert time.monotonic() < deadline, 'preference not persisted on disk'
            time.sleep(0.5)
        d.cli('sb', 'system-apps', 'set', 'maybe', sudo=True, expected=1)
    finally:
        d.cli('sb', 'system-apps', 'set', 'on' if original['visible'] else 'off', sudo=True)
    assert d.cli('sb', 'system-apps', 'get')['visible'] is original['visible']
    if not original['configured']:
        d.observations.append('SBShowNonDefaultSystemApps was absent before the test; it is now stored explicitly as false, which is the same default.')


@case('account_password', 'system', ['account set-password'])
def account_password(d):
    password = d.env.get('ICLI_SSH_PASSWORD')
    assert password, 'account_password needs ICLI_SSH_PASSWORD so the runner can log in with the new value and restore the original'
    temporary = 'icli-acceptance-' + uuid.uuid4().hex[:12]
    snapshot = d.run(['sh', '-c', 'grep ^mobile /var/jb/etc/master.passwd | cut -d: -f2'], sudo=True)
    before = snapshot.stdout.strip()
    snapshot.icli_trace['stdout'] = '<redacted account hash>'
    assert before.startswith('$6$'), 'expected a sha512-crypt hash for mobile'
    d.cli('account', 'set-password', 'mobile', expected=1)
    assert d.run([d.binary, 'account', 'set-password', 'nobody-here'], sudo=True).returncode == 1

    def change(current, new):
        result = subprocess.run(d.prefix + ['ssh', '-p', d.port] + d.options + [d.user + '@' + d.host, 'sudo -S -p "" ' + shlex.join([d.binary, 'account', 'set-password', 'mobile'])],
                                env=dict(d.env, SSHPASS=current), input=current + '\n' + new + '\n', capture_output=True, text=True, timeout=60)
        d.trace.append({'command': 'account set-password mobile (stdin)', 'cli_arguments': ['account', 'set-password', 'mobile'], 'exit': result.returncode, 'seconds': 0, 'stdout': result.stdout[:2000], 'stderr': result.stderr[:500]})
        assert result.returncode == 0, result.stdout + result.stderr
        return json.loads(result.stdout)

    changed = change(password, temporary)
    try:
        assert changed['user'] == 'mobile' and changed['spwd_db_records'] == 3 and changed['scheme'] == 'sha512crypt', changed
        login = subprocess.run(d.prefix + ['ssh', '-p', d.port, '-o', 'NumberOfPasswordPrompts=1'] + d.options + [d.user + '@' + d.host, 'sudo -S -p "" sh -c "id -u; grep ^mobile /var/jb/etc/master.passwd | cut -d: -f2"'],
                               env=dict(d.env, SSHPASS=temporary), input=temporary + '\n', capture_output=True, text=True, timeout=60)
        assert login.returncode == 0 and login.stdout.splitlines()[0] == '0', 'new password rejected by sshd or sudo: ' + login.stderr
        stored = login.stdout.splitlines()[1]
        assert stored != before and stored == subprocess.run(['openssl', 'passwd', '-6', '-salt', changed['salt'], '-stdin'], input=temporary + '\n', capture_output=True, text=True, check=True).stdout.strip(), 'stored hash does not match sha512-crypt'
        assert temporary not in json.dumps(d.trace), 'password leaked into the trace'
    finally:
        restored = change(temporary, password)
    assert restored['spwd_db_records'] == 3
    assert d.run(['id', '-u'], sudo=True).stdout.strip() == '0', 'original password no longer works'
    d.observations.append('The new password is read from stdin and never appears in argv or the trace; the rootfs account database is untouched, so the stock system password remains valid for iOS itself.')


@case('environment_report', 'runtime', ['env info', 'env basebin'])
def environment(d):
    env = d.cli('env')
    assert env['layout'] == 'rootless' and env['jbroot'] == '/var/jb' and env['platform_binary'] is True, env
    assert env['bootstrap_tools_present']['dpkg'] is True and env['roothide_runtime_active'] is False
    assert env['external_tools_used'] == {} and env['spawns_processes'] is False, env
    assert d.cli('env', 'info', sudo=True)['euid'] == 0
    absent = d.cli('env', 'basebin')
    assert absent['installed_present'] is False and 'bundled' not in absent, absent
    d.observations.append('This vphone has no BaseBin (no /var/jb/basebin/.version); the installed side of the comparison reports installed_present=false.')
    archive = '/tmp/icli-basebin-' + uuid.uuid4().hex + '.tar'
    assert d.run(['sh', '-c', f'rm -rf /tmp/icli-bb && mkdir -p /tmp/icli-bb/basebin && printf "2.3.4\\n" > /tmp/icli-bb/basebin/.version && tar -C /tmp/icli-bb -cf {archive} basebin && rm -rf /tmp/icli-bb']).returncode == 0
    try:
        compared = d.cli('env', 'basebin', '--bundled', archive)
        assert compared['bundled'] == '2.3.4' and compared['bundled_present'] and compared['matches'] is False and compared['update_available'] is True, compared
    finally:
        d.run(['rm', '-f', archive])
    d.cli('env', 'basebin', '--bundled', '/tmp/icli-no-such.tar', expected=1)


@case('boot_logo_render', 'system', ['device bootlogo'])
def boot_logo(d):
    mark = '/tmp/icli-mark-' + uuid.uuid4().hex + '.jpg'
    output = '/tmp/icli-bootlogo-' + uuid.uuid4().hex + '.jp2'
    try:
        d.cli('screen', 'shot', '--output', mark)
        screen = d.cli('screen', 'info')
        for dark in [True, False]:
            rendered = d.cli('device', 'bootlogo', '--mark', mark, '--output', output, *(['--dark'] if dark else []))
            assert rendered['format'] == 'public.jpeg-2000' and rendered['bytes'] > 1000, rendered
            assert rendered['width'] == round(screen['width'] * screen['scale']) and rendered['height'] == round(screen['height'] * screen['scale']), rendered
            assert max(rendered['mark_pixels']) == round(128 * screen['scale'])
            head = base64.b64decode(d.cli('fs', 'read', output, '--binary', '--limit', '12')['content'])
            assert head == b'\x00\x00\x00\x0cjP  \r\n\x87\n', head
        custom = d.cli('device', 'bootlogo', '--mark', mark, '--output', output, '--width', '640', '--height', '480', '--mark-points', '64')
        assert custom['width'] == 640 and custom['height'] == 480 and max(custom['mark_pixels']) == round(64 * screen['scale']), custom
        d.cli('device', 'bootlogo', '--mark', '/tmp/icli-no-mark.png', '--output', output, expected=1)
    finally:
        d.run(['rm', '-f', mark, output])


def wait_for_reconnect(d, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if d.run(['true'], timeout=15).returncode == 0:
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(3)
    return False


def request_reboot(d, userspace=False):
    arguments = ['device', 'reboot'] + (['--userspace'] if userspace else []) + ['--force']
    result = d.run([d.binary] + arguments, sudo=True)
    result.icli_trace['cli_arguments'] = arguments
    if result.returncode == 0:
        accepted = json.loads(result.stdout)
        assert accepted['accepted'] and accepted['kind'] == ('userspace' if userspace else 'full'), accepted
    else:
        assert result.returncode == 255, result.stdout + result.stderr
        d.observations.append('SSH disconnected during the reboot call before a JSON response; completion is checked after reconnecting, not inferred from the disconnect.')


@case('userspace_reboot', 'reboot', ['device reboot'])
def userspace_reboot(d):
    d.cli('device', 'reboot', '--userspace', sudo=True, expected=1)
    d.cli('device', 'reboot', '--userspace', '--force', expected=1)
    before = d.cli('device', 'info')
    session, boot = before['boot_session_uuid'], before['boot_time']
    names = ['logd', 'notifyd', 'SpringBoard']
    def service_pids():
        processes = d.cli('proc', 'list')['processes']
        pids = {p['name']: p['pid'] for p in processes if p['name'] in names}
        assert set(pids) == set(names), pids
        return pids
    pids_before = service_pids()
    request_reboot(d, userspace=True)
    time.sleep(20)
    assert wait_for_reconnect(d, 240), 'device did not come back after the userspace reboot'
    after = d.cli('device', 'info')
    assert after['boot_session_uuid'] == session, 'kernel boot session changed: this was a full reboot'
    assert after['boot_time'] == boot, 'kernel boot time changed: this was a full reboot'
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        d.cli('button', 'wake', expected=None)
        if d.cli('env', expected=None).get('layout') == 'rootless' and d.cli('screen', 'info', expected=None).get('locked') is False:
            break
        time.sleep(3)
    assert d.cli('env')['platform_binary'] is True
    pids_after = service_pids()
    assert all(pids_after[name] != pids_before[name] for name in names), (pids_before, pids_after)
    d.observations.append(f'Userspace restart replaced system and UI services: {pids_before} -> {pids_after}; kernel boot time and boot session UUID remained unchanged.')
    d.fixture()
    assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE


@case('device_reboot', 'reboot', ['device reboot'])
def device_reboot(d):
    boot = d.cli('device', 'info')['boot_time']
    d.cli('fs', 'write', '/tmp/icli-reboot-marker', 'before-reboot', sudo=True)
    request_reboot(d)
    time.sleep(30)
    assert wait_for_reconnect(d, 420), 'device did not come back after the reboot'
    assert d.cli('device', 'info')['boot_time'] != boot, 'kernel boot time unchanged: the device did not reboot'
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        d.cli('button', 'wake', expected=None)
        if d.cli('env', expected=None).get('layout') == 'rootless' and d.cli('screen', 'info', expected=None).get('locked') is False:
            break
        time.sleep(3)
    assert d.cli('env')['platform_binary'] is True and d.cli('svc', 'status', 'com.openssh.sshd')['loaded']
    assert d.cli('fs', 'read', '/tmp/icli-reboot-marker', expected=1).get('error'), '/tmp survived the full reboot'
    d.observations.append('A full reboot clears /tmp, so the install fixtures and TestHost must be uploaded again before rerunning other groups.')


@case('repository_configuration', 'packages', ['pkg repos', 'pkg add-repo'])
def repositories(d):
    path = '/var/jb/etc/apt/sources.list.d/icli.list'
    backup = '/tmp/icli-repo-backup-' + uuid.uuid4().hex
    saved = d.run(['test', '-e', path]).returncode == 0
    if saved:
        assert d.run(['cp', '-p', path, backup], sudo=True).returncode == 0
    url = 'https://icli-acceptance.invalid/' + uuid.uuid4().hex
    try:
        assert d.cli('pkg', 'add-repo', url, sudo=True)['added'] is True
        assert d.cli('pkg', 'add-repo', url, sudo=True)['added'] is False
        assert url in json.dumps(d.cli('pkg', 'repos'))
        d.cli('pkg', 'add-repo', 'invalid\nrepository', sudo=True, expected=1)
    finally:
        if saved:
            assert d.run(['mv', backup, path], sudo=True).returncode == 0
        else:
            assert d.run(['rm', '-f', path], sudo=True).returncode == 0


@case('keychain_fixture', 'security', ['sec keychain list', 'sec keychain get', 'sec keychain add', 'sec keychain update', 'sec keychain delete'])
def keychain(d):
    service = 'icli.acceptance.' + uuid.uuid4().hex
    selection = ['--class', 'generic_password', '--service', service, '--account', 'acceptance', '--group', 'icli.test']
    assert d.cli('sec', 'keychain', 'list', *selection)['count'] == 0
    created = False
    try:
        created = True
        d.cli('sec', 'keychain', 'add', *selection, '--data', 'fixture-before')
        created = True
        listed = d.cli('sec', 'keychain', 'list', *selection)
        assert listed['count'] == 1 and 'data' not in listed['items'][0]
        assert d.cli('sec', 'keychain', 'get', *selection)['items'][0]['data'] == 'fixture-before'
        d.cli('sec', 'keychain', 'update', *selection, '--data', 'fixture-after')
        assert d.cli('sec', 'keychain', 'get', *selection)['items'][0]['data'] == 'fixture-after'
        d.cli('sec', 'keychain', 'delete', *selection, expected=1)
    finally:
        if created:
            d.cli('sec', 'keychain', 'delete', *selection, '--force')
    assert d.cli('sec', 'keychain', 'list', *selection)['count'] == 0
    d.cli('sec', 'keychain', 'get', *selection, expected=1)


@case('system_inspection', 'runtime', ['device network', 'device ioreg', 'sec ssl-killswitch'])
def system_inspection(d):
    addresses = d.cli('device', 'network')['addresses']
    assert any('127.0.0.1' in value for value in addresses)
    registry = d.cli('device', 'ioreg')
    assert registry, registry
    assert isinstance(d.cli('sec', 'ssl-killswitch')['present'], bool)


@case('icon_cache', 'system', ['sb uicache'])
def icon_cache(d):
    refreshed = d.cli('sb', 'uicache', sudo=True, timeout=90)
    assert refreshed['directory'].endswith('/Applications') and not refreshed['failed'] and not refreshed['unverified'], refreshed
    assert any(path.endswith('/IcliTestHost.app') for path in refreshed['registered'])
    d.fixture()
    assert d.cli('app', 'frontmost')['bundle_id'] == BUNDLE


@case('loopback_packet_capture', 'network', ['net capture'])
def network_capture(d):
    for value in ['nan', '-1', '0', '61']:
        d.cli('net', 'capture', '--seconds=' + value, expected=1)
    d.fixture()
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=1) as pool:
        capture = pool.submit(d.cli, 'net', 'capture', '--seconds', '3', '--interface', 'lo0', '--filter', 'udp port 54321', sudo=True)
        time.sleep(0.5)
        d.cli('url', 'open', 'icli-test://network-probe')
        assert d.state()['network_bytes'] > 0
        result = capture.result()
    assert 2 <= time.monotonic() - start < 8
    try:
        assert result['bytes'] > 24 and result['interface'] == 'lo0'
        packet = d.run(['tcpdump', '-n', '-r', result['path']])
        assert packet.returncode == 0 and 'UDP' in packet.stdout and '54321' in packet.stdout, packet.stdout
    finally:
        assert d.run(['rm', '-f', result['path']], sudo=True).returncode == 0


@case('springboard_restart', 'system', ['sb respring'])
def springboard_restart(d):
    def springboard_pid():
        return [p['pid'] for p in d.cli('proc', 'list', '--filter', 'SpringBoard')['processes'] if p['name'] == 'SpringBoard']
    before = springboard_pid()
    assert before, 'SpringBoard is not running'
    restarted = d.cli('sb', 'respring', timeout=30)
    assert restarted['restarted'] and restarted['previous_pid'] == before[0] and restarted['pid'] != before[0], restarted
    assert restarted['method'] == 'frontboard_relaunch', restarted
    time.sleep(3)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        # SpringBoard comes back on the lock screen with the display off, which
        # blocks interactive commands. The device has no passcode, so button
        # wake (allowed while locked) must leave it usable again.
        d.cli('button', 'wake', expected=None)
        time.sleep(1)
        listed = d.cli('proc', 'list', '--filter', 'SpringBoard', expected=None)
        after = [p['pid'] for p in listed.get('processes', []) if p['name'] == 'SpringBoard']
        if after and after != before:
            break
    else:
        raise AssertionError('SpringBoard did not restart')
    info = d.cli('screen', 'info')
    assert not info['locked'] and not info['screen_off'], info
    # Root uses the same FrontBoard path; SpringBoard's pid must change again.
    second = springboard_pid()
    again = d.cli('sb', 'respring', sudo=True, timeout=30)
    assert again['restarted'] and again['previous_pid'] == second[0] and again['pid'] != second[0], again
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        d.cli('button', 'wake', expected=None)
        if d.cli('screen', 'info', expected=None).get('locked') is False:
            break
        time.sleep(1)
    assert d.cli('screen', 'info')['locked'] is False


def command_inventory(command, prefix=()):
    children = command.get('subcommands', [])
    if children:
        return [name for child in children for name in command_inventory(child, prefix + (child['commandName'],))]
    return [' '.join(prefix)] if prefix and prefix != ('help',) else []


def observed_commands(cases, inventory):
    observed = set()
    for case in cases:
        for trace in case['trace']:
            arguments = trace.get('cli_arguments', [])
            for command in inventory:
                words = command.split()
                if arguments[:len(words)] == words:
                    observed.add(command)
    return observed

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group', choices=['all', 'runtime', 'ax', 'gestures', 'input', 'screen', 'logs', 'apps', 'controls', 'install', 'packages', 'security', 'network', 'system', 'reboot'], default='all')
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--skip-reboot', action='store_true', help='Leave out the reboot group (the run is then not a full run).')
    parser.add_argument('--case', action='append', dest='cases', help='Run only named cases (repeatable).')
    parser.add_argument('--report', default='.build/acceptance.json')
    args = parser.parse_args()
    (ROOT / '.build').mkdir(exist_ok=True)
    device = Device()
    if args.install:
        device.install()
    fingerprint = device.run(['sha256sum', device.binary])
    assert fingerprint.returncode == 0, fingerprint.stderr
    local_hash = hashlib.sha256((ROOT / '.build/icli').read_bytes()).hexdigest()
    assert fingerprint.stdout.split()[0] == local_hash, 'device binary differs from local build'
    version = device.run([device.binary, '--version'])
    help_output = device.run([device.binary, '--experimental-dump-help'])
    assert help_output.returncode == 0, help_output.stderr
    inventory = command_inventory(json.loads(help_output.stdout)['command'])
    report = {'environment': 'rootless', 'binary_sha256': fingerprint.stdout.split()[0],
              'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'version': version.stdout.strip(), 'device': device.cli('device', 'info'), 'cases': []}
    if args.cases:
        unknown = set(args.cases) - {c[0] for c in CASES}
        if unknown:
            parser.error('Unknown cases: ' + ', '.join(sorted(unknown)))
    report['command_inventory'] = inventory
    report['full_run'] = args.group == 'all' and not args.cases and not args.skip_reboot
    report['tested_at'] = datetime.now(timezone.utc).isoformat()
    # The reboot group disconnects the device, so it always runs last.
    ordered = [c for c in CASES if c[1] != 'reboot'] + [c for c in CASES if c[1] == 'reboot']
    report['planned_cases'] = [name for name, group, _, _ in ordered
                               if (args.group == 'all' or args.group == group)
                               and (not args.cases or name in args.cases)
                               and not (args.skip_reboot and group == 'reboot')]
    for name, group, tools, test in ordered:
        if args.group != 'all' and args.group != group:
            continue
        if args.cases and name not in args.cases:
            continue
        if args.skip_reboot and group == 'reboot':
            continue
        device.trace = []
        device.observations = []
        start = time.monotonic()
        try:
            test(device)
            result = {'name': name, 'tools': tools, 'passed': True}
        except Exception as error:
            result = {'name': name, 'tools': tools, 'passed': False, 'error': str(error)}
        result['seconds'] = round(time.monotonic()-start, 3)
        result['trace'] = device.trace
        result['observations'] = device.observations
        report['cases'].append(result)
        report['completed_run'] = len(report['cases']) == len(report['planned_cases'])
        print(('PASS' if result['passed'] else 'FAIL') + ' ' + name + ' ' + result.get('error', ''), flush=True)
        report['untested_commands'] = sorted(set(inventory) - observed_commands(report['cases'], inventory))
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2))
    complete = not report['full_run'] or not report['untested_commands']
    return 0 if report['cases'] and complete and all(case['passed'] for case in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
