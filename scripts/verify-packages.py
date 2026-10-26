#!/usr/bin/env python3
"""Verify signed single-binary package invariants after check-packages.sh extracts them."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tarfile

root = Path(__file__).resolve().parents[1]
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
verifier = runpy.run_path(str(root / 'scripts/verify-binary.py'))


def verify_binary(binary, platform, sdk_name, extra_frameworks=()):
    """The checks every shipped executable passes, whichever platform it is for."""
    entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(binary)]))
    assert entitlements == plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
    assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
    build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    # The CLI, the package and the DEB's firmware dependency share one floor.
    # The SDK is the one it was built with: a lower stamp sends newer systems
    # down their old-SDK compatibility paths.
    sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-version'], text=True).strip()
    fields = [line.split() for line in build.splitlines()]
    assert ['platform', platform] in fields and ['minos', '15.0'] in fields and ['sdk', sdk] in fields, build
    loads = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for load in loads:
        name = load.strip().split(' (')[0]
        assert name.startswith(('/System/Library/', '/usr/lib/')), name
        assert 'libarchive' not in name, 'libarchive must be statically linked'
    verifier['verify_javascriptcore_not_linked'](binary)
    report = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'architecture': 'arm64',
              'system_loads': loads, 'javascriptcore_linked': False}
    report.update(verifier['verify_no_process_imports'](binary))
    report.update(verifier['verify_floor_imports'](binary, sdk_name, extra_frameworks))
    return report


ios = verify_binary(root / '.build/icli', 'IOS', 'iphoneos')
report = {'version': version, **ios, 'minimum_ios': '15.0', 'packages': []}
# tvOS is its own executable: the same sources built against the AppleTVOS
# SDK, with IOKit's headers from the stub the tvOS build links against.
tvos = verify_binary(root / '.build/icli-tvos', 'TVOS', 'appletvos', [root / '.build/tvos-stubs'])
report['tvos'] = {'binary': 'icli-tvos', **tvos, 'minimum_tvos': '15.0'}
for kind, arch, prefix, digest in [('rootless', 'iphoneos-arm64', 'var/jb', ios['binary_sha256']),
                                   ('roothide', 'iphoneos-arm64e', '', ios['binary_sha256']),
                                   ('tvos', 'appletvos-arm64', '', tvos['binary_sha256'])]:
    package = root / f'.build/com.icli.icli_{version}_{arch}.deb'
    folder = root / '.build/package-check' / kind / prefix
    cli = folder / 'usr/bin/icli'
    assert hashlib.sha256(cli.read_bytes()).hexdigest() == digest
    assert not (folder / 'Applications').exists(), 'CLI package must not contain an app'
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Architecture'], text=True).strip() == arch
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Version'], text=True).strip() == version
    dependencies = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Depends'], text=True).strip()
    assert dependencies == 'firmware (>= 15.0)', dependencies
    archive = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(package)])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        members = tar.getmembers()
        assert all(m.uid == 0 and m.gid == 0 for m in members)
        executables = [m for m in members if m.isfile() and m.mode & 0o111]
        assert len(executables) == 1 and executables[0].name.endswith('/icli'), executables
    report['packages'].append({'layout': kind, 'file': package.name,
                               'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
                               'binary_sha256': digest, 'depends': dependencies,
                               'single_binary': True, 'root_owned': True})
(root / '.build/package-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS iOS and tvOS package architecture, metadata, entitlements, system dependencies, ownership, '
      'CLI-only contents, JavaScriptCore loaded at runtime and no process-launch imports')
