#!/usr/bin/env python3
"""macOS-only regression checks using disposable keys and tiny fake app images.

Never reads the publisher's keys, starts GigaFlow, or touches its installation.
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Update tooling checks require macOS.')
    source = Path(__file__).resolve().parent.parent
    subprocess.run(['/bin/bash', str(source / 'scripts/fetch-sparkle.sh')], check=True)
    checked = 0
    with tempfile.TemporaryDirectory(prefix='gigaflow-update-tool-checks.') as temporary:
        root = Path(temporary)
        repo = root / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'dist').mkdir()
        for name in ('setup-update-signing.swift', 'make-appcast.sh', 'fetch-sparkle.sh'):
            shutil.copyfile(source / 'scripts' / name, repo / 'scripts' / name)
        (repo / 'vendor').symlink_to(source / 'vendor', target_is_directory=True)
        log = root / 'checks.log'

        def run(args, env=None, expect_success=True):
            result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, env=env)
            with log.open('a') as stream:
                stream.write(result.stdout + result.stderr)
            if expect_success and result.returncode:
                raise RuntimeError('Isolated update-tool command failed:\n' +
                                   '\n'.join(log.read_text().splitlines()[-20:]))
            return result

        def expect(condition, description):
            nonlocal checked
            if not condition:
                raise RuntimeError(description)
            checked += 1

        setup = repo / 'scripts/setup-update-signing.swift'

        def key_command(directory, *args, expect_success=True):
            return run(['xcrun', 'swift', setup, '--directory', directory, *args],
                       expect_success=expect_success)

        identity = root / 'identity'
        expect(key_command(identity, '--check', expect_success=False).returncode != 0 and not identity.exists(),
               'Check-only mode created an identity')
        public_key = key_command(identity).stdout.strip()
        expect(bool(public_key), 'Setup did not return a public key')
        private = identity / 'private-key.base64'
        public = identity / 'public-key.base64'
        original = private.read_bytes()
        public_bytes = public.read_bytes()
        expect(private.stat().st_mode & 0o777 == 0o600, 'Private key is not mode0600')
        expect(identity.stat().st_mode & 0o777 == 0o700, 'Identity directory is not mode0700')
        expect(key_command(identity, '--check').stdout.strip() == public_key, 'Repeated check changed public identity')
        expect(key_command(identity).stdout.strip() == public_key and private.read_bytes() == original,
               'Repeated setup replaced private key')
        private.chmod(0o644)
        expect(key_command(identity, '--check', expect_success=False).returncode != 0,
               'Shared private key permissions accepted')
        private.chmod(0o600)
        private.write_text('invalid key')
        expect(key_command(identity, expect_success=False).returncode != 0 and private.read_text() == 'invalid key',
               'Invalid private key was accepted or regenerated')
        private.write_bytes(original)
        public.write_text('unrelated public key')
        expect(key_command(identity, expect_success=False).returncode != 0 and private.read_bytes() == original,
               'Mismatched public key was accepted or private key was replaced')
        public.write_bytes(public_bytes)
        orphan = root / 'orphan'
        orphan.mkdir(mode=0o700)
        (orphan / public.name).write_bytes(public_bytes)
        expect(key_command(orphan, expect_success=False).returncode != 0 and not (orphan / private.name).exists(),
               'Losing a private key silently created a new identity')
        private.unlink()
        target = root / 'target-key'
        target.write_bytes(original)
        target.chmod(0o600)
        private.symlink_to(target)
        expect(key_command(identity, expect_success=False).returncode != 0 and target.read_bytes() == original,
               'Private-key symlink was accepted or modified')
        private.unlink()
        private.write_bytes(original)
        private.chmod(0o600)

        def image_for(version, build):
            folder = root / ('image-' + version)
            app = folder / 'GigaFlow.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            shutil.copyfile('/bin/echo', app / 'Contents/MacOS/GigaFlow')
            (app / 'Contents/MacOS/GigaFlow').chmod(0o755)
            info = {'CFBundleIdentifier': 'local.arseniy.gigaflow', 'CFBundleName': 'GigaFlow',
                    'CFBundleExecutable': 'GigaFlow', 'CFBundlePackageType': 'APPL',
                    'CFBundleShortVersionString': version, 'CFBundleVersion': str(build),
                    'LSMinimumSystemVersion': '26.2', 'SUPublicEDKey': public_key,
                    'SUFeedURL': 'https://github.com/aspalagin/GigaFlow/releases/latest/download/appcast.xml',
                    'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True}
            with (app / 'Contents/Info.plist').open('wb') as stream:
                plistlib.dump(info, stream)
            run(['/usr/bin/codesign', '--force', '--sign', '-', app])
            image = repo / 'dist' / ('GigaFlow-' + version + '-arm64.dmg')
            run(['/usr/bin/hdiutil', 'create', '-volname', 'GigaFlowAppcastTest',
                 '-srcfolder', folder, '-format', 'UDZO', image])
            return image

        environment = dict(os.environ, GIGAFLOW_UPDATE_SIGNING_DIR=str(identity))
        make = repo / 'scripts/make-appcast.sh'
        first = image_for('0.4.0', 8)
        run(['/bin/bash', make, first], env=environment)
        feed = repo / 'dist/appcast.xml'
        expect(feed.exists(), 'Signed feed was not created')
        ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
        tree = ET.parse(feed)
        expect(tree.findtext('./channel/item/' + ns + 'version') == '8', 'Build missing from feed')
        signature = tree.find('./channel/item/enclosure').get(ns + 'edSignature')
        expect(bool(signature), 'Archive signature missing from feed')
        verifier = repo / 'vendor/Sparkle-2.10.1/bin/sign_update'
        damaged_archive = root / 'damaged.dmg'
        damaged_archive.write_bytes(first.read_bytes() + b'changed-after-signing')
        expect(run([verifier, '--ed-key-file', private, '--verify', damaged_archive, signature],
                   expect_success=False).returncode != 0, 'Modified archive passed EdDSA verification')
        run(['/bin/bash', make, first], env=environment)
        expect(len(ET.parse(feed).findall('./channel/item')) == 1, 'Repeated generation added a duplicate release')
        second = image_for('0.4.1', 9)
        run(['/bin/bash', make, second], env=environment)
        expect([node.text for node in ET.parse(feed).findall('./channel/item/' + ns + 'version')] == ['9', '8'],
               'Previous release was not retained in the next feed')
        valid = feed.read_bytes()
        expect(run(['/bin/bash', make, first], env=environment, expect_success=False).returncode != 0,
               'Downgrade was accepted')
        expect(feed.read_bytes() == valid, 'Rejected downgrade replaced valid output')
        tampered = root / 'tampered.xml'
        damaged_feed = valid.replace(b'<title>0.4.1</title>', b'<title>tampered</title>')
        expect(damaged_feed != valid, 'Feed-tampering fixture did not alter data')
        tampered.write_bytes(damaged_feed)
        expect(run(['/bin/bash', make, second, tampered], env=environment, expect_success=False).returncode != 0,
               'Tampered previous feed was accepted')
        expect(feed.read_bytes() == valid, 'Rejected tampered input replaced valid output')
        different_identity = root / 'different-identity'
        key_command(different_identity)
        wrong_environment = dict(environment, GIGAFLOW_UPDATE_SIGNING_DIR=str(different_identity))
        expect(run(['/bin/bash', make, second], env=wrong_environment, expect_success=False).returncode != 0,
               'Publisher key mismatch was accepted')
        expect(feed.read_bytes() == valid, 'Wrong publisher key replaced valid output')
        print('Update signing and appcast tooling: %d isolated checks passed' % checked)


if __name__ == '__main__':
    main()
