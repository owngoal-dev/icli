#!/usr/bin/env python3
"""Build a separate iOS consumer against a tagged snapshot of this package."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', action='store_true', help='Sign the test consumer and run it through the acceptance SSH configuration.')
args = parser.parse_args()
work = root / '.build/package-consumer'
snapshot = work / 'icli'
consumer = work / 'consumer'
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
work.mkdir(parents=True, exist_ok=True)
for folder in [snapshot, consumer]:
    if folder.exists():
        shutil.rmtree(folder)
snapshot.mkdir()
for name in ['Sources', 'Resources']:
    shutil.copytree(root / name, snapshot / name)
shutil.copy2(root / 'Package.swift', snapshot / 'Package.swift')
shutil.copy2(root / 'Package.resolved', snapshot / 'Package.resolved')

def git(*arguments):
    subprocess.run(['git', '-C', str(snapshot), *arguments], check=True, capture_output=True)

git('init', '--quiet')
git('add', '.')
git('-c', 'user.name=Package Test', '-c', 'user.email=package-test@localhost',
    '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Package consumer fixture')
git('tag', version)
shutil.copytree(root / 'Tests/PackageConsumer', consumer, ignore=shutil.ignore_patterns('.build', '.swiftpm', 'Package.resolved'))
manifest = consumer / 'Package.swift'
manifest.write_text(manifest.read_text().replace('.package(path: "../..")',
                    f'.package(url: "{snapshot.as_uri()}", exact: "{version}")'))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
command = ['swift', 'build', '--package-path', str(consumer), '--scratch-path', str(work / 'build'),
           '-c', 'release', '--triple', 'arm64-apple-ios16.0', '--sdk', sdk, '--product', 'IcliPackageConsumer']
subprocess.run(command, check=True)
sources = [root / 'Package.swift'] + sorted((root / 'Sources').rglob('*')) + sorted((root / 'Resources').rglob('*'))
source_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in sources if path.is_file()}
checkout = work / 'build/checkouts/icli'
for path, digest in source_hashes.items():
    assert hashlib.sha256((checkout / path).read_bytes()).hexdigest() == digest, 'consumer resolved stale source: ' + path
output = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip()) / 'IcliPackageConsumer'
binary = work / 'IcliPackageConsumer'
shutil.copy2(output, binary)
report = {'version': version, 'product': 'IcliKit', 'dependency_kind': 'source-control exact version',
          'unsigned_consumer_binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'source_sha256': source_hashes,
          'manifest_sha256': hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest()}
if args.device:
    entitlements = plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
    identifier = 'dev.owngoal.icli.PackageConsumer'
    for key in ['application-identifier', 'com.apple.application-identifier']:
        entitlements[key] = identifier
    signing = work / 'consumer.entitlements'
    signing.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(['ldid', '-S' + str(signing), str(binary)], check=True)
    device = runpy.run_path(str(root / 'scripts/acceptance.py'))['Device']()
    remote = '/tmp/icli-package-consumer'
    device.upload(binary, remote)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    fingerprint = device.run(['sha256sum', remote])
    assert fingerprint.returncode == 0 and fingerprint.stdout.split()[0] == digest
    result = device.run([remote])
    assert result.returncode == 0, result.stdout + result.stderr
    report['signed_consumer_binary_sha256'] = digest
    report['application_identifier'] = identifier
    report['device_result'] = json.loads(result.stdout)
    device.run(['rm', '-f', remote])
(root / '.build/package-consumer-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS external versioned Swift Package consumer:', binary)
