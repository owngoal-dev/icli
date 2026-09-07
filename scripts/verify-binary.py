#!/usr/bin/env python3
"""Reject process-launch imports in the shipped Mach-O."""
from pathlib import Path
import re
import subprocess


def verify_no_process_imports(binary):
    output = subprocess.check_output(['nm', '-u', str(binary)], text=True)
    forbidden = re.compile(r'^_(?:posix_spawn.*|exec[lv].*|system|popen|fork|vfork)$|NSTask')
    imports = sorted({line.split()[-1] for line in output.splitlines() if line.strip()})
    found = [symbol for symbol in imports if forbidden.search(symbol)]
    if found:
        raise SystemExit('Forbidden process-launch imports: ' + ', '.join(found))
    return {'undefined_symbols_checked': len(imports), 'forbidden_process_imports': found}


if __name__ == '__main__':
    binary = Path(__file__).resolve().parents[1] / '.build/icli'
    verify_no_process_imports(binary)
    print('PASS no process-launch imports')
