#!/usr/bin/env python3
"""Reject process-launch imports, and strong imports iOS 15.0 may not export, in the shipped Mach-O."""
from pathlib import Path
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def verify_no_process_imports(binary):
    output = subprocess.check_output(['nm', '-u', str(binary)], text=True)
    forbidden = re.compile(r'^_(?:posix_spawn.*|exec[lv].*|system|popen|fork|vfork)$|NSTask')
    imports = sorted({line.split()[-1] for line in output.splitlines() if line.strip()})
    found = [symbol for symbol in imports if forbidden.search(symbol)]
    if found:
        raise SystemExit('Forbidden process-launch imports: ' + ', '.join(found))
    return {'undefined_symbols_checked': len(imports), 'forbidden_process_imports': found}


def sdk_declared_names():
    """Every identifier any public header in the iPhoneOS SDK spells."""
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip())
    names = set()
    # os.walk, not rglob: several frameworks in the SDK are symlinks, and
    # rglob does not follow a symlinked directory (SafariServices is one)
    for folder in [sdk / 'usr/include', sdk / 'System/Library/Frameworks']:
        for directory, _, files in os.walk(folder, followlinks=True):
            for file in files:
                if file.endswith('.h'):
                    text = (Path(directory) / file).read_text(errors='ignore')
                    names.update(re.findall(r'[A-Za-z_$][A-Za-z0-9_$]*', text))
    return names


def verify_floor_imports(binary):
    """Strong imports must be SDK-declared (the 15.0 triple weak-links newer
    ones) or listed in floor-imports.txt as exported by iOS 15.0. Mangled
    Swift symbols are left to the compiler, which weak-links them from their
    availability; the runtime's C entry points are not, so they are listed."""
    allowed = set()
    for line in (ROOT / 'scripts/floor-imports.txt').read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            allowed.add(line)
    output = subprocess.check_output(['nm', '-m', '-u', str(binary)], text=True)
    strong = set()
    for line in output.splitlines():
        if '(undefined)' not in line or ' weak ' in line:
            continue
        symbol = line.split()[2]
        name = symbol[1:] if symbol.startswith('_') else symbol
        # A class reference is checked by the class name its header spells.
        name = re.sub(r'^OBJC_(?:META)?CLASS_\$_', '', name)
        if name.startswith(('$s', '_Tt')):
            continue
        strong.add(name)
    declared = sdk_declared_names()
    unknown = sorted(name for name in strong if name not in declared and name not in allowed)
    if unknown:
        raise SystemExit(
            'Strong imports no SDK header declares and floor-imports.txt does not list: ' + ', '.join(unknown)
            + '\nConfirm iOS 15.0 exports each one and list it, or resolve it with dlsym.'
        )
    return {'strong_imports_checked': len(strong), 'unlisted_private_imports': unknown}


if __name__ == '__main__':
    binary = ROOT / '.build/icli'
    verify_no_process_imports(binary)
    print('PASS no process-launch imports')
    verify_floor_imports(binary)
    print('PASS no strong import beyond the iOS 15.0 floor')
