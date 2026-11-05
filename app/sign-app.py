#!/usr/bin/env python3
"""Sign local GigaFlow updates with the same certificate-bound identity."""
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

BASE = Path.home() / 'Library/Application Support/GigaFlow/Signing'
APP_ID = 'local.arseniy.gigaflow'


def main():
    if len(sys.argv) != 2:
        raise RuntimeError('Usage: sign-app.py /path/to/GigaFlow.app')
    app = Path(sys.argv[1]).resolve(strict=True)
    if not (BASE / 'identity.json').is_file():
        raise RuntimeError('Persistent signing identity missing. Run setup-signing.py once; ad-hoc fallback is disabled.')
    identity = json.loads((BASE / 'identity.json').read_text())
    fingerprint = identity['certificate_sha1'].upper()
    if not re.fullmatch(r'[0-9A-F]{40}', fingerprint):
        raise RuntimeError('Invalid signing certificate fingerprint')
    keychain = Path(identity['keychain_path']).resolve(strict=True)
    keychain.relative_to(BASE.resolve())
    password = (BASE / 'keychain-password.txt').read_text().strip()
    requirement = 'identifier "' + APP_ID + '" and certificate leaf = H"' + fingerprint + '"'

    def run(args):
        result = subprocess.run(args, text=True, capture_output=True)
        if result.returncode:
            detail = (result.stderr + result.stdout).replace(password, '[REDACTED]')
            raise RuntimeError(Path(args[0]).name + ': ' + detail.strip())
        return result

    certificate = run(['/usr/bin/openssl', 'x509', '-in', str(BASE / 'signing-cert.pem'),
                       '-noout', '-fingerprint', '-sha1']).stdout
    actual = certificate.strip().split('=')[-1].replace(':', '').upper()
    if actual != fingerprint:
        raise RuntimeError('Signing certificate changed; refusing to change application identity')
    unlocked = False
    original_keychains = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']).stdout)
    try:
        if str(keychain) not in original_keychains:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original_keychains, str(keychain)])
        run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
        unlocked = True
        run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
             '--identifier', APP_ID, '--requirements', '=designated => ' + requirement,
             '--timestamp=none', str(app)])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement, str(app)])
        print('Verified stable signature: ' + fingerprint)
    finally:
        try:
            if unlocked:
                run(['/usr/bin/security', 'lock-keychain', str(keychain)])
        finally:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original_keychains])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
