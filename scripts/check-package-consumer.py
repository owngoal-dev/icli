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
# The snapshot keeps the repository version as its tag, so a rerun at the same
# version must also drop the resolved checkout or SwiftPM reuses the old one.
for folder in [snapshot, consumer, work / 'build']:
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

def build(product, triple):
    command = ['swift', 'build', '--package-path', str(consumer), '--scratch-path', str(work / 'build'),
               '-c', 'release', '--triple', triple, '--sdk', sdk, '--product', product]
    subprocess.run(command, check=True)
    return command

command = build('IcliPackageConsumer', 'arm64-apple-ios16.0')
# The read-only product at the package's floor: an app that deploys to iOS 15
# can link IcliSystem, which the library product is there to allow.
system_command = build('IcliSystemConsumer', 'arm64-apple-ios15.0')
sources = [root / 'Package.swift'] + sorted((root / 'Sources').rglob('*')) + sorted((root / 'Resources').rglob('*'))
source_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in sources if path.is_file()}
checkout = work / 'build/checkouts/icli'
for path, digest in source_hashes.items():
    assert hashlib.sha256((checkout / path).read_bytes()).hexdigest() == digest, 'consumer resolved stale source: ' + path
output = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip()) / 'IcliPackageConsumer'
binary = work / 'IcliPackageConsumer'
shutil.copy2(output, binary)
system_output = Path(subprocess.check_output(system_command + ['--show-bin-path'], text=True).strip()) / 'IcliSystemConsumer'
system_binary = work / 'IcliSystemConsumer'
shutil.copy2(system_output, system_binary)
report = {'version': version, 'product': 'IcliKit', 'dependency_kind': 'source-control exact version',
          'unsigned_consumer_binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'system_product': 'IcliSystem', 'system_minimum_ios': '15.0',
          'unsigned_system_consumer_binary_sha256': hashlib.sha256(system_binary.read_bytes()).hexdigest(),
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
    folder = '/var/tmp/icli-package-consumer'
    remote = folder + '/IcliPackageConsumer'
    # RootHide binaries find the jbroot through a .jbroot link beside them, as
    # in its /usr/bin; a copied binary in a plain folder would miss it.
    made = device.run(f'rm -rf {folder} && mkdir {folder} && if [ -L /usr/bin/.jbroot ]; then ln -s ../../../.jbroot {folder}/.jbroot; fi')
    assert made.returncode == 0, made.stderr
    device.upload(binary, remote)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    fingerprint = device.run(['sha256sum', remote])
    assert fingerprint.returncode == 0 and fingerprint.stdout.split()[0] == digest
    result = device.run([remote])
    device.run(['rm', '-rf', folder])
    assert result.returncode == 0, result.stdout + result.stderr
    report['signed_consumer_binary_sha256'] = digest
    report['application_identifier'] = identifier
    report['device_result'] = json.loads(result.stdout)
(root / '.build/package-consumer-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS external versioned Swift Package consumer:', binary)
print('PASS iOS 15 IcliSystem consumer:', system_binary)
