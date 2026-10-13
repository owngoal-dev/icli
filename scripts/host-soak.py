#!/usr/bin/env python3
"""Build Tests/HostSoak and run it on the acceptance device as a long-running
IcliKit host. Uses the same SSH settings as scripts/acceptance.py."""
import argparse
import json
from pathlib import Path
import plistlib
import runpy
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iterations', type=int, default=150)
parser.add_argument('--root', action='store_true', help='Run as root, the way a launch daemon does.')
parser.add_argument('--report', default='.build/host-soak.json')
args = parser.parse_args()
package = root / 'Tests/HostSoak'
scratch = root / '.build/host-soak'
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(scratch), '-c', 'release',
           '--triple', 'arm64-apple-ios15.0', '--sdk', sdk, '--product', 'IcliHostSoak']
subprocess.run(command, check=True)
binary = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip()) / 'IcliHostSoak'
signed = scratch / 'IcliHostSoak'
signed.write_bytes(binary.read_bytes())
signed.chmod(0o755)
entitlements = plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
for key in ['application-identifier', 'com.apple.application-identifier']:
    entitlements[key] = 'dev.owngoal.icli.HostSoak'
(scratch / 'soak.entitlements').write_bytes(plistlib.dumps(entitlements))
subprocess.run(['ldid', '-S' + str(scratch / 'soak.entitlements'), str(signed)], check=True)

device = runpy.run_path(str(root / 'scripts/acceptance.py'))['Device']()
folder = '/var/tmp/icli-host-soak'
# RootHide binaries find the jbroot through a .jbroot link beside them.
made = device.run(f'rm -rf {folder} && mkdir {folder} && if [ -L /usr/bin/.jbroot ]; then ln -s ../../../.jbroot {folder}/.jbroot; fi')
assert made.returncode == 0, made.stderr
device.upload(signed, folder + '/IcliHostSoak')
try:
    result = device.run(f'SOAK_ITERATIONS={args.iterations} {folder}/IcliHostSoak', timeout=1800, sudo=args.root)
finally:
    device.run(['rm', '-rf', folder], sudo=args.root)
print(result.stdout)
if result.stderr:
    print(result.stderr)
report = json.loads(result.stdout) if result.stdout.strip().startswith('{') else {'stderr': result.stderr}
report['exit'] = result.returncode
(root / args.report).write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(result.returncode)
