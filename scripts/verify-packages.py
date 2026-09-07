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
binary = root / '.build/icli'
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(binary)]))
assert entitlements == plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
assert 'platform IOS' in build and 'minos 16.0' in build, build
loads = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
for load in loads:
    name = load.strip().split(' (')[0]
    assert name.startswith(('/System/Library/', '/usr/lib/')), name
    assert 'libarchive' not in name, 'libarchive must be statically linked'
report = {'version': version, 'binary_sha256': digest, 'architecture': 'arm64',
          'minimum_ios': '16.0', 'system_loads': loads, 'packages': []}
report.update(runpy.run_path(str(root / 'scripts/verify-binary.py'))['verify_no_process_imports'](binary))
for kind, arch, prefix in [('rootless', 'iphoneos-arm64', 'var/jb'), ('roothide', 'iphoneos-arm64e', '')]:
    package = root / f'.build/com.icli.icli_{version}_{arch}.deb'
    folder = root / '.build/package-check' / kind / prefix
    cli = folder / 'usr/bin/icli'
    assert hashlib.sha256(cli.read_bytes()).hexdigest() == digest
    assert not (folder / 'Applications').exists(), 'CLI package must not contain an app'
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Architecture'], text=True).strip() == arch
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Version'], text=True).strip() == version
    dependencies = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Depends'], text=True).strip()
    assert dependencies == 'firmware (>= 16.0)', dependencies
    archive = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(package)])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        members = tar.getmembers()
        assert all(m.uid == 0 and m.gid == 0 for m in members)
        executables = [m for m in members if m.isfile() and m.mode & 0o111]
        assert not any(m.name.endswith(('.traineddata', 'ClipboardApp.plist')) for m in members)
        assert len(executables) == 1 and executables[0].name.endswith('/icli'), executables
    report['packages'].append({'layout': kind, 'file': package.name,
                               'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
                               'depends': dependencies,
                               'single_binary': True, 'root_owned': True})
(root / '.build/package-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS package architecture, metadata, entitlements, system dependencies, ownership, CLI-only contents and no process-launch imports')
