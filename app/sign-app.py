#!/usr/bin/env python3
"""Sign local GigaFlow updates with the same certificate-bound identity."""
import json
import hashlib
import re
import shlex
import subprocess
import sys
from pathlib import Path

BASE = Path.home() / 'Library/Application Support/GigaFlow/Signing'
APP_ID = 'local.arseniy.gigaflow'
MACHO_MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def nested_binaries(app):
    runtime = app / 'Contents/Resources/Runtime'
    if not runtime.exists():
        return []
    result = []
    for path in sorted(runtime.rglob('*')):
        if path.is_symlink():
            path.resolve(strict=True).relative_to(app)
            continue
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    result.append(path)
    return result


def sparkle_components(app):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    if not framework.exists():
        return []
    # Sparkle's documented inside-out signing sequence. The downloader has its
    # own sandbox/network entitlements; they must not leak into other helpers.
    components = [
        (framework / 'Versions/B/XPCServices/Installer.xpc', False),
        (framework / 'Versions/B/XPCServices/Downloader.xpc', True),
        (framework / 'Versions/B/Autoupdate', False),
        (framework / 'Versions/B/Updater.app', False),
        (framework, False),
    ]
    for path, _ in components:
        path.resolve(strict=True).relative_to(app)
    return components


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
        binaries = nested_binaries(app)
        # Sign each nested executable explicitly before sealing the outer bundle.
        # Never use --deep for signing or ship this keychain with the application.
        for binary in binaries:
            relative = str(binary.relative_to(app))
            identifier = APP_ID + '.runtime.' + hashlib.sha256(relative.encode()).hexdigest()[:20]
            nested_requirement = 'identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"'
            run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
                 '--identifier', identifier, '--requirements', '=designated => ' + nested_requirement,
                 '--timestamp=none', str(binary)])
            run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + nested_requirement, str(binary)])
        updater_components = sparkle_components(app)
        for component, preserve_entitlements in updater_components:
            metadata = 'identifier,entitlements' if preserve_entitlements else 'identifier'
            run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
                 '--options', 'runtime', '--preserve-metadata=' + metadata,
                 '--timestamp=none', str(component)])
            run(['/usr/bin/codesign', '--verify', '--strict', str(component)])
        run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
             '--identifier', APP_ID, '--requirements', '=designated => ' + requirement,
             '--timestamp=none', str(app)])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement, str(app)])
        print('Verified stable signature: ' + fingerprint)
        if binaries:
            print('Verified nested native binaries: ' + str(len(binaries)))
        if updater_components:
            print('Verified Sparkle updater components: ' + str(len(updater_components)))
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
