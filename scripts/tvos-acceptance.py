#!/usr/bin/env python3
"""tvOS acceptance tests through a vphone guest's control socket.

Run on the Mac that hosts the VM, beside .build/icli-tvos (make tvos) and
.build/tvos-fixtures (scripts/build-tvos-fixtures.sh):

    python3 scripts/tvos-acceptance.py --vm tvhd [--respring]

A tvOS guest has no shell or bootstrap, so icli runs as root through vphoned's
script session (proc.run) and files arrive through the socket's push. The
TestHost's accessibility labels are the oracle. TVSetup must be finished:
PineBoard launches no app while Setup Assistant runs.
"""
import argparse
import json
import plistlib
import re
import socket
import tempfile
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = '/var/root/icli-acceptance'
BINARY = WORK + '/icli'
APPS = '/var/mobile/icli-tvtest'
APP = APPS + '/IcliTVTestHost.app'
TEST_APP = 'dev.owngoal.icli.TVTestHost'
CONTAINER_APP = 'dev.owngoal.icli.TVTestHost.Container'
LABEL = 'dev.owngoal.icli.tvtest.kickstart'
# Siri Remote presses on the consumer page.
SELECT, UP, DOWN, MENU = '65', '66', '67', '70'
SCREEN_SAVER = 'com.apple.IdleScreen'
CASES = []


def case(name):
    def register(fn):
        CASES.append((name, fn))
        return fn
    return register


class Guest:
    def __init__(self, vm):
        self.socket = Path(f'~/.vphone/machines/{vm}/vphone.sock').expanduser()
        self.trace = []

    def call(self, request, timeout=600):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(str(self.socket))
            connection.sendall((json.dumps(request) + '\n').encode())
            data = b''
            while chunk := connection.recv(1 << 20):
                data += chunk
                try:
                    return json.loads(data)
                except ValueError:
                    continue
        return json.loads(data)

    def push(self, local, path, mode='644'):
        reply = self.call({'t': 'push', 'local': str(Path(local).resolve()), 'path': path, 'mode': mode})
        assert reply.get('ok'), f'push {local} -> {path}: {reply}'

    def proc(self, program, args, stdin='', timeout=180):
        source = f'proc.run({json.dumps(program)}, {json.dumps(args)}, {json.dumps(stdin)})'
        reply = self.call({'t': 'rpc', 'method': 'script.eval', 'params': {'source': source, 'timeout': timeout}}, timeout + 30)
        value = (reply.get('result') or {}).get('result')
        run = json.loads(value) if isinstance(value, str) else value
        assert isinstance(run, dict), f'{program} {args}: no result: {reply}'
        return run

    def cli(self, *args, expected=0, stdin=''):
        """icli's parsed output; asserts the exit status unless `expected` is None."""
        run = self.proc(BINARY, list(args), stdin)
        self.trace.append({'args': list(args), 'status': run.get('status'), 'stdout': run.get('stdout', '')[:4000],
                           'stderr': run.get('stderr', '')[:1000]})
        if expected is not None and run.get('status') != expected:
            raise AssertionError(f"icli {' '.join(args)} exited {run.get('status')} (signal {run.get('signal')}), "
                                 f"expected {expected}: {run.get('stdout', '')[:500]} {run.get('stderr', '')[:300]}")
        try:
            return json.loads(run.get('stdout', ''))
        except ValueError:
            return run.get('stdout', '')

    def wait_for(self, text, timeout=8):
        return self.cli('ui', 'wait', text, '--timeout', str(timeout))

    def press(self, usage):
        self.cli('input', 'hid', '12', usage)
        time.sleep(0.8)

    def poll(self, check, seconds=10):
        deadline = time.time() + seconds
        while True:
            value = check()
            if value or time.time() > deadline:
                return value
            time.sleep(0.5)


def read_file(g, path):
    return g.cli('fs', 'read', path)['content']


@case('environment')
def environment(g):
    assert re.fullmatch(r'\d+\.\d+\.\d+', g.cli('--version').strip())
    env = g.cli('env', 'info')
    assert env['layout'] is None and env['euid'] == 0, env
    assert env['external_tools_used'] == {} or env['external_tools_used'] == [], env
    device = g.cli('device', 'info')
    assert device['model'].startswith('AppleTV'), device
    assert device['battery']['fraction'] == -1, device['battery']
    screen = g.cli('screen', 'info')
    assert screen['width'] > screen['height'] > 0, screen


@case('read_only_commands')
def read_only_commands(g):
    g.cli('button', 'wake')
    for args in [['device', 'jetsam'], ['device', 'brightness', 'get'], ['device', 'volume', 'get'],
                 ['device', 'rotation', 'get'], ['device', 'rotation', 'lock', 'get'], ['device', 'network'],
                 ['device', 'ioreg'], ['device', 'low-power', 'get'], ['device', 'timezone', 'get'],
                 ['screen', 'describe'], ['app', 'search', 'Settings'], ['app', 'schemes'],
                 ['app', 'binary', 'com.apple.TVSettings'], ['app', 'data', 'com.apple.TVSettings'],
                 ['fs', 'ls', '/System/Library/CoreServices'], ['fs', 'find', '/System/Library/CoreServices', 'SystemVersion'],
                 ['fs', 'plist', '/System/Library/CoreServices/SystemVersion.plist'],
                 ['log', 'syslog', '--seconds', '2', '--max-lines', '20'], ['log', 'crashes'],
                 ['pkg', 'repos'], ['pkg', 'tweaks'], ['sb', 'system-apps', 'get'], ['svc', 'print-disabled'],
                 ['svc', 'print', 'com.apple.lsd'], ['svc', 'paths', '/System/Library/LaunchDaemons/com.apple.lsd.plist'],
                 ['svc', 'getenv', 'PATH'], ['sec', 'keychain', 'list', '--group', 'icli.test'], ['sec', 'keychain', 'database'],
                 ['prefs', 'read', '.GlobalPreferences', 'AppleLanguages'], ['notify', 'get', 'com.apple.springboard.lockstate']]:
        g.cli(*args)
    assert g.cli('pkg', 'compare', '1.0', '1.0.1')['relation'] == 'lt'
    apps = {app['bundle_id'] for app in g.cli('app', 'list')['apps']}
    assert {'com.apple.TVSettings', 'com.apple.HeadBoard', 'com.apple.PineBoard'} <= apps
    frontmost = g.cli('app', 'frontmost')
    assert frontmost['verified'] and frontmost['source'] == 'runningboard', frontmost
    assert g.cli('app', 'running')['source'] == 'runningboard'
    assert g.cli('app', 'info', 'com.apple.TVSettings')['bundle_path'] == '/Applications/TVSettings.app'
    assert g.cli('app', 'handlers', 'http')['count'] >= 1
    services = g.cli('svc', 'list')
    assert services['count'] > 100, services['count']
    dump = g.cli('svc', 'dump')
    assert dump['described'] == dump['count'] and not dump['errors'], dump['errors']
    shell = g.cli('svc', 'status', 'com.apple.PineBoard')
    assert shell['loaded'] and shell['running'] and shell['pid'] > 0, shell
    assert g.cli('proc', 'list', '--filter', 'PineBoard')['count'] == 1
    shot = g.cli('screen', 'shot', '--output', WORK + '/shot.jpg')
    assert shot['width'] == screen_width(g) and shot['bytes'] > 10000, shot
    tests = g.cli('tests')
    assert tests['failed'] == 0, tests


def screen_width(g):
    return g.cli('screen', 'info')['width']


@case('unavailable_on_tvos')
def unavailable_on_tvos(g):
    for args in [['clipboard', 'get'], ['clipboard', 'set', 'x'], ['screen', 'tap', '10', '10'],
                 ['screen', 'double-tap', '10', '10'], ['screen', 'long-press', '10', '10'],
                 ['screen', 'swipe', '--from-x', '10', '--from-y', '10', '--to-x', '20', '--to-y', '20'],
                 ['screen', 'drag', '--points', '[{"x":10,"y":10},{"x":20,"y":20}]'],
                 ['screen', 'touch', 'down', '10', '10'], ['screen', 'click', '10', '10'], ['screen', 'scroll', '10', '10'],
                 ['ui', 'tap', 'anything'], ['device', 'rotation', 'set', '0'], ['device', 'rotation', 'lock', 'set', 'on'],
                 ['app', 'network', 'get', 'com.apple.TVSettings']]:
        result = g.cli(*args, expected=1)
        assert result['error'] == 'unavailable', (args, result)


@case('launchd_lifecycle')
def launchd_lifecycle(g, fixtures):
    daemon, state, plist = WORK + '/kickstart-daemon', WORK + '/kickstart.state', WORK + f'/{LABEL}.plist'
    g.push(fixtures / 'kickstart-daemon-1', daemon, '755')
    with tempfile.NamedTemporaryFile(suffix='.plist') as local:
        local.write(plistlib.dumps({'Label': LABEL, 'ProgramArguments': [daemon, state], 'RunAtLoad': False, 'KeepAlive': False}))
        local.flush()
        g.push(local.name, plist)
    try:
        assert not g.cli('svc', 'paths', plist)['errors']
        assert g.cli('svc', 'bootstrap', plist)['loaded']
        status = g.cli('svc', 'status', LABEL)
        assert status['loaded'] and not status.get('running'), status
        assert g.cli('svc', 'start', LABEL)['accepted']
        running = g.poll(lambda: (s := g.cli('svc', 'status', LABEL)).get('running') and s)
        assert running and running['pid'] > 0, running
        first = g.poll(lambda: read_file(g, state).strip())
        assert first == f"1 {running['pid']}", first
        # Replace the executable; the running daemon keeps the old file, and
        # kickstart without -k leaves it running.
        g.push(fixtures / 'kickstart-daemon-2', daemon + '.new', '755')
        g.cli('fs', 'rm', daemon, '--force')
        g.cli('fs', 'move', daemon + '.new', daemon)
        g.cli('svc', 'kickstart', LABEL)
        assert read_file(g, state).strip() == first
        restarted = g.cli('svc', 'kickstart', '--kill', LABEL)
        assert restarted['pid'] and restarted['pid'] != running['pid'], restarted
        assert g.poll(lambda: read_file(g, state).strip() == f"2 {restarted['pid']}")
        # The fixture pauses with launchd's signal dispositions; KILL ends it either way.
        g.cli('svc', 'kill', 'KILL', LABEL)
        assert g.poll(lambda: not g.cli('svc', 'status', LABEL).get('running'))
        assert not g.cli('svc', 'disable', LABEL)['enabled']
        assert LABEL in json.dumps(g.cli('svc', 'print-disabled'))
        assert g.cli('svc', 'enable', LABEL)['enabled']
        assert not g.cli('svc', 'bootout', plist)['loaded']
        assert not g.cli('svc', 'status', LABEL)['loaded']
        assert g.cli('svc', 'load', plist)['loaded']
        assert not g.cli('svc', 'unload', plist)['loaded']
        assert g.cli('svc', 'bootstrap', plist)['loaded']
        g.cli('svc', 'remove', LABEL)
        assert g.poll(lambda: not g.cli('svc', 'status', LABEL)['loaded'])
        assert g.cli('svc', 'setenv', 'ICLI_TVTEST', 'tv')['verified']
        assert g.cli('svc', 'getenv', 'ICLI_TVTEST')['value'] == 'tv'
        assert g.cli('svc', 'unsetenv', 'ICLI_TVTEST')['verified']
        assert not g.cli('svc', 'getenv', 'ICLI_TVTEST')['exists']
    finally:
        g.cli('svc', 'bootout', plist, expected=None)
        g.cli('svc', 'enable', LABEL, expected=None)
        g.cli('svc', 'unsetenv', 'ICLI_TVTEST', expected=None)


@case('uicache_register_launch_refresh')
def uicache_register_launch_refresh(g, fixtures):
    g.cli('fs', 'mkdir', APPS, expected=None)
    g.cli('fs', 'mkdir', APP, expected=None)
    for name, mode in [('Info.plist', '644'), ('IcliTVTestHost', '755')]:
        g.push(fixtures / 'IcliTVTestHost.app' / name, f'{APP}/{name}', mode)
    try:
        registered = g.cli('app', 'register', APP)
        # PineBoard disables system apps the programming guide did not provision.
        assert registered['registered'] and registered['type'] == 'User', registered
        assert registered['data_path'] and 'group.dev.owngoal.icli.tvtest' in registered['group_containers'], registered
        refreshed = g.cli('app', 'refresh', '--directory', APPS)
        assert any(p.endswith('/IcliTVTestHost.app') for p in refreshed['unchanged']), refreshed
        assert TEST_APP in [a['bundle_id'] for a in g.cli('app', 'handlers', 'icli-tvtest')['apps']]
        assert g.cli('app', 'launch', TEST_APP)['frontmost']
        frontmost = g.cli('app', 'frontmost')
        assert frontmost['bundle_id'] == TEST_APP and frontmost['verified'], frontmost
        identifiers = {e['identifier'] for e in g.cli('ui', 'tree')['elements']}
        assert {'screen.title', 'status', 'button.press', 'input.text'} <= identifiers, identifiers
        g.wait_for('Ready')
        # Focus starts on the button; Select presses it.
        g.press(SELECT)
        g.wait_for('Pressed')
        g.press(DOWN)
        g.press(SELECT)
        g.cli('input', 'type', 'icli tv')
        g.cli('input', 'key', 'return')
        g.wait_for('Typed: icli tv')
        for command, url in [(['app', 'open'], 'icli-tvtest://app'), (['url', 'open'], 'icli-tvtest://url'),
                             (['app', 'open', '--bundle', TEST_APP], 'icli-tvtest://bundle')]:
            g.cli(*command[:2], url, *command[2:])
            g.wait_for('Opened ' + url)
        assert g.cli('app', 'kill', '--force', TEST_APP)['pids']
        assert g.cli('app', 'frontmost')['bundle_id'] != TEST_APP
        # plist-set takes JSON: the build is a string.
        g.cli('fs', 'plist-set', APP + '/Info.plist', 'CFBundleVersion', '"2"')
        refreshed = g.cli('app', 'refresh', '--directory', APPS)
        assert any(p.endswith('/IcliTVTestHost.app') for p in refreshed['registered']), refreshed
        assert g.cli('app', 'info', TEST_APP)['build'] == '2'
        g.cli('fs', 'rm', APP, '--recursive', '--force')
        refreshed = g.cli('app', 'refresh', '--directory', APPS)
        assert any(p.endswith('/IcliTVTestHost.app') for p in refreshed['unregistered']), refreshed
        g.cli('app', 'info', TEST_APP, expected=1)
    finally:
        g.cli('app', 'kill', '--force', TEST_APP, expected=None)
        g.cli('app', 'unregister', APP, '--force', expected=None)
        g.cli('fs', 'rm', APPS, '--recursive', '--force', expected=None)


@case('container_install')
def container_install(g, fixtures):
    ipa = WORK + '/IcliTVTestHostContainer.ipa'
    g.push(fixtures / 'IcliTVTestHostContainer.ipa', ipa)
    try:
        installed = g.cli('app', 'install', ipa, '--container')
        assert installed['bundle_id'] == CONTAINER_APP and installed['registration'] == 'user', installed
        assert installed['bundle_container'].startswith('/private/var/containers/Bundle/Application/'), installed
        assert g.cli('app', 'launch', CONTAINER_APP)['frontmost']
        g.wait_for('Ready')
        g.cli('app', 'kill', '--force', CONTAINER_APP)
        g.cli('app', 'uninstall', CONTAINER_APP, '--force')
        g.cli('app', 'info', CONTAINER_APP, expected=1)
    finally:
        g.cli('app', 'uninstall', CONTAINER_APP, '--force', expected=None)


@case('files_preferences_keychain')
def files_preferences_keychain(g):
    folder = WORK + '/files'
    try:
        g.cli('fs', 'mkdir', folder)
        g.cli('fs', 'write', folder + '/a.txt', 'tvOS 中文 🌱')
        assert g.cli('fs', 'read', folder + '/a.txt')['content'] == 'tvOS 中文 🌱'
        g.cli('fs', 'copy', folder + '/a.txt', folder + '/b.txt')
        g.cli('fs', 'move', folder + '/b.txt', folder + '/c.txt')
        assert g.cli('fs', 'link', folder + '/a.txt', folder + '/l.txt')['resolved'].endswith('/a.txt')
        g.cli('fs', 'chmod', folder + '/a.txt', '600')
        g.cli('fs', 'chown', folder + '/a.txt', '501:501')
        assert {e['name'] for e in g.cli('fs', 'ls', folder)['entries']} == {'a.txt', 'c.txt', 'l.txt'}
    finally:
        g.cli('fs', 'rm', folder, '--recursive', '--force', expected=None)
    domain = 'dev.owngoal.icli.tvtest'
    assert g.cli('prefs', 'write', domain, 'Count', '42', '--type', 'int')['value'] == 42
    assert g.cli('prefs', 'read', domain, 'Count')['value'] == 42
    assert g.cli('prefs', 'delete', domain, 'Count')['removed']
    assert g.cli('notify', 'post', domain, '--state', '7')['delivered']
    keychain = ['--group', 'icli.test', '--service', 'tvtest', '--account', 'acceptance']
    try:
        assert g.cli('sec', 'keychain', 'add', *keychain, '--data', 'one')['ok']
        assert g.cli('sec', 'keychain', 'get', *keychain)['count'] == 1
        g.cli('sec', 'keychain', 'update', *keychain, '--data', 'two')
        assert g.cli('sec', 'keychain', 'delete', *keychain, '--force')['deleted']
    finally:
        g.cli('sec', 'keychain', 'delete', *keychain, '--force', expected=None)


@case('device_controls')
def device_controls(g):
    zone = g.cli('device', 'timezone', 'get')['identifier']
    volume = g.cli('device', 'volume', 'get')['volume']
    try:
        assert g.cli('device', 'timezone', 'set', 'America/New_York')['identifier'] == 'America/New_York'
        assert abs(g.cli('device', 'volume', 'set', '0.3')['volume'] - 0.3) < 0.01
        assert g.cli('button', 'volume-up')['method'] in ('hid', 'audio_control')
        assert g.cli('net', 'capture', '--seconds', '1', '--output', WORK + '/capture.pcap')['interface']
    finally:
        g.cli('device', 'timezone', 'set', zone, expected=None)
        g.cli('device', 'volume', 'set', str(volume), expected=None)


@case('screen_saver')
def screen_saver(g):
    # Menu goes back, and on the Home screen starts the screen saver, which
    # covers everything and is reported in front; wake dismisses it.
    g.cli('button', 'wake')

    def started():
        g.press(MENU)
        return g.poll(lambda: g.cli('app', 'frontmost')['bundle_id'] == SCREEN_SAVER, 3)
    assert any(started() for _ in range(4)), g.cli('app', 'frontmost')
    frontmost = g.cli('app', 'frontmost')
    assert frontmost['verified'] and frontmost['source'] == 'runningboard', frontmost
    woke = g.cli('button', 'wake')
    assert not woke['locked'] and not woke['screen_off'], woke
    frontmost = g.cli('app', 'frontmost')
    assert frontmost['bundle_id'] == 'com.apple.HeadBoard' and frontmost['verified'], frontmost


@case('probe')
def probe(g):
    # icli probe evaluates JavaScript inline; the result is one JSON line.
    assert g.cli('probe', '-e', '1 + 2')['result'] == '3'
    name = g.cli('probe', '-e', "ObjC.use('NSProcessInfo').processInfo().processName()")
    assert name['ok'] and name['result'], name
    # console output is captured into the result, not printed beside the line.
    printed = g.cli('probe', '-e', "console.log('tv probe'); 7")
    assert printed['ok'] and printed['result'] == '7' and printed['output'] == 'tv probe\n', printed
    # api() reaches icli's own capabilities in process.
    assert g.cli('probe', '-e', "api('env.info').spawns_processes")['result'] == 'false'
    assert g.cli('probe', '-e', "api('svc.list').count > 100")['result'] == 'true'
    model = g.cli('probe', '-e', "api('device.info').model")
    assert model['ok'] and 'AppleTV' in model['result'], model
    # The reflection bridge calls a method and reads its result.
    version = g.cli('probe', '-e', "ObjC.use('NSProcessInfo').processInfo().operatingSystemVersionString()")
    assert version['ok'] and version['result'], version
    # A thrown script is an answer with ok:false and a nonzero exit.
    threw = g.cli('probe', '-e', "throw new Error('tvboom')", expected=1)
    assert not threw['ok'] and 'tvboom' in threw['error'], threw
    # Params JSON cannot hold, a path with no file-system form and half an
    # emoji are answers too, never a crash that loses the line.
    encoded = g.cli('probe', '-e', "api('env.info', {n: NaN, d: new Date(0)}).spawns_processes")
    assert encoded['ok'] and encoded['result'] == 'false', encoded
    empty = g.cli('probe', '-e', "fs.stat('')", expected=1)
    assert not empty['ok'] and 'Invalid argument' in empty['error'], empty
    half = g.cli('probe', '-e', "console.log('kept'); console.log('\\ud83d'); 1")
    assert half['ok'] and half['result'] == '1' and half['output'] == 'kept\n\ufffd\n', half
    # alloc().init() on a real allocation, collected many times over, must not
    # over-release; a JS function passed for a block is refused, not called.
    owned = g.cli('probe', '-e', "for (var i = 0; i < 20000; i++) ObjC.use('NSObject').alloc().init();"
                  "var junk = []; for (var j = 0; j < 300000; j++) junk.push({j: j}); 'owned'")
    assert owned['ok'] and owned['result'] == 'owned', owned
    block = g.cli('probe', '-e', "ObjC.use('NSMutableArray').arrayWithObject_('x').enumerateObjectsUsingBlock_(function () {})", expected=1)
    assert not block['ok'] and 'block argument' in block['error'], block
    # A leading underscore stays part of a private method's name.
    private = g.cli('probe', '-e', "ObjC.use('NSObject').new()._isDeallocating()")
    assert private['ok'] and private['result'] == 'false', private
    # A script that cannot be read is answered on the same JSON line.
    missing = g.cli('probe', '/no/such/icli-probe-script.js', expected=1)
    assert not missing['ok'] and 'cannot read script' in missing['error'] and missing['output'] == '', missing


@case('respring')
def respring(g):
    before = g.cli('svc', 'status', 'com.apple.PineBoard')['pid']
    restarted = g.cli('sb', 'respring')
    assert restarted['restarted'] and restarted['pid'] != before, restarted
    g.cli('button', 'wake')
    assert g.poll(lambda: g.cli('app', 'frontmost')['verified'], 20)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--vm', default='tvhd')
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/icli-tvos')
    parser.add_argument('--fixtures', type=Path, default=ROOT / '.build/tvos-fixtures')
    parser.add_argument('--respring', action='store_true', help='Also restart PineBoard.')
    parser.add_argument('--report', type=Path, default=ROOT / '.build/tvos-acceptance.json')
    parser.add_argument('--case', action='append', help='Run only this case (repeatable).')
    args = parser.parse_args()
    g = Guest(args.vm)
    # The socket's push creates the folders above the file.
    g.push(args.binary, BINARY, '755')
    results = []
    for name, fn in CASES:
        if (name == 'respring' and not args.respring) or (args.case and name not in args.case):
            continue
        started = time.time()
        try:
            fn(g, args.fixtures) if fn.__code__.co_argcount == 2 else fn(g)
            results.append({'case': name, 'passed': True, 'seconds': round(time.time() - started, 1)})
            print(f'PASS {name}')
        except Exception as error:
            results.append({'case': name, 'passed': False, 'error': f'{type(error).__name__}: {error}',
                            'traceback': traceback.format_exc()})
            print(f'FAIL {name}: {type(error).__name__}: {str(error)[:600]}')
    passed = sum(r['passed'] for r in results)
    device = g.cli('device', 'info')
    report = {'vm': args.vm, 'model': device.get('model'), 'os': device.get('ios_version'),
              'passed': passed, 'total': len(results), 'results': results, 'trace': g.trace}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
    print(f'{passed}/{len(results)} passed on {device.get("model")} tvOS {device.get("ios_version")}; report {args.report}')
    raise SystemExit(0 if passed == len(results) else 1)


if __name__ == '__main__':
    main()
