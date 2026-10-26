#!/usr/bin/env python3
"""Build separate iOS and tvOS consumers against a tagged snapshot of this package."""
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
manifest.write_text(manifest.read_text().replace('.package(name: "icli", path: "../..")',
                    f'.package(url: "{snapshot.as_uri()}", exact: "{version}")'))
assert snapshot.as_uri() in manifest.read_text(), 'the consumer manifest no longer names the path dependency'
sdks = {name: subprocess.check_output(['xcrun', '--sdk', name, '--show-sdk-path'], text=True).strip()
        for name in ['iphoneos', 'appletvos']}
# The AppleTVOS SDK has no IOKit.framework, which IcliKit links; a tvOS host
# builds against the same stub the CLI's tvOS build makes. IcliSystem and
# IcliLaunch do not use IOKit and need nothing extra.
stubs = work / 'tvos-stubs'
subprocess.run([str(root / 'scripts/tvos-iokit-stub.sh'), str(stubs)], check=True)
stub_flags = ['-Xcc', f'-F{stubs}', '-Xswiftc', f'-F{stubs}', '-Xlinker', f'-F{stubs}']

def build(product, triple, sdk='iphoneos', flags=()):
    command = ['swift', 'build', '--package-path', str(consumer), '--scratch-path', str(work / 'build'),
               '-c', 'release', '--triple', triple, '--sdk', sdks[sdk], '--product', product, *flags]
    subprocess.run(command, check=True)
    return Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip()) / product

output = build('IcliPackageConsumer', 'arm64-apple-ios15.0')
# The read-only product at the package's floor: an app that deploys to iOS 15
# can link IcliSystem, which the library product is there to allow.
system_output = build('IcliSystemConsumer', 'arm64-apple-ios15.0')
# The launch product at the same floor, and without the heavy half: an
# executable that only brings an app forward must not link UIKit or ArchiveKit.
launch_output = build('IcliLaunchConsumer', 'arm64-apple-ios15.0')
# The same three products for tvOS at its own 15 floor.
tvos_outputs = {
    'IcliPackageConsumer': build('IcliPackageConsumer', 'arm64-apple-tvos15.0', 'appletvos', stub_flags),
    'IcliSystemConsumer': build('IcliSystemConsumer', 'arm64-apple-tvos15.0', 'appletvos'),
    'IcliLaunchConsumer': build('IcliLaunchConsumer', 'arm64-apple-tvos15.0', 'appletvos'),
}
for launch in [launch_output, tvos_outputs['IcliLaunchConsumer']]:
    launch_links = subprocess.check_output(['otool', '-L', str(launch)], text=True)
    for framework in ['UIKit', 'IOKit', 'AVFoundation', 'libarchive']:
        assert framework not in launch_links, 'IcliLaunch consumer links ' + framework
sources = [root / 'Package.swift'] + sorted((root / 'Sources').rglob('*')) + sorted((root / 'Resources').rglob('*'))
source_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in sources if path.is_file()}
checkout = work / 'build/checkouts/icli'
for path, digest in source_hashes.items():
    assert hashlib.sha256((checkout / path).read_bytes()).hexdigest() == digest, 'consumer resolved stale source: ' + path
binary = work / 'IcliPackageConsumer'
shutil.copy2(output, binary)
system_binary = work / 'IcliSystemConsumer'
shutil.copy2(system_output, system_binary)
launch_binary = work / 'IcliLaunchConsumer'
shutil.copy2(launch_output, launch_binary)
# The library shapes an app links, checked on their own: dead-stripping can
# leave an import here that the CLI never reaches.
verifier = runpy.run_path(str(root / 'scripts/verify-binary.py'))
floor_imports = {path.name: verifier['verify_floor_imports'](path) for path in [binary, system_binary, launch_binary]}
verifier['verify_javascriptcore_not_linked'](binary)
tvos_binaries = {}
for product, output in tvos_outputs.items():
    tvos_binaries[product] = work / 'tvos' / product
    tvos_binaries[product].parent.mkdir(exist_ok=True)
    shutil.copy2(output, tvos_binaries[product])
    build_version = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(output)], text=True)
    fields = [line.split() for line in build_version.splitlines()]
    assert ['platform', 'TVOS'] in fields and ['minos', '15.0'] in fields, build_version
tvos_floor_imports = {name: verifier['verify_floor_imports'](path, 'appletvos', [stubs]) for name, path in tvos_binaries.items()}
verifier['verify_javascriptcore_not_linked'](tvos_binaries['IcliPackageConsumer'])
report = {'version': version, 'product': 'IcliKit', 'dependency_kind': 'source-control exact version',
          'unsigned_consumer_binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'system_product': 'IcliSystem', 'system_minimum_ios': '15.0',
          'unsigned_system_consumer_binary_sha256': hashlib.sha256(system_binary.read_bytes()).hexdigest(),
          'launch_product': 'IcliLaunch', 'launch_minimum_ios': '15.0',
          'unsigned_launch_consumer_binary_sha256': hashlib.sha256(launch_binary.read_bytes()).hexdigest(),
          'tvos_minimum': '15.0',
          'unsigned_tvos_consumer_binary_sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in tvos_binaries.items()},
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
report['floor_imports'] = floor_imports
report['tvos_floor_imports'] = tvos_floor_imports
(root / '.build/package-consumer-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS external versioned Swift Package consumer:', binary)
print('PASS iOS 15 IcliSystem consumer:', system_binary)
print('PASS iOS 15 IcliLaunch consumer without UIKit or ArchiveKit:', launch_binary)
print('PASS tvOS 15 IcliKit (with the IOKit stub), IcliSystem and IcliLaunch consumers:', work / 'tvos')
