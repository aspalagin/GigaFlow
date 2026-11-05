#!/usr/bin/env python3
"""Create GigaFlow's persistent, private local signing identity on this Mac.

No login-keychain password, certificate trust settings, TCC database, or global
security policy is changed. An incomplete setup is never regenerated silently.
Private PEM/P12 intermediates are removed; the key remains non-extractable in
the dedicated encrypted keychain. Only public identity metadata is printed.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile

APP_IDENTIFIER = "local.arseniy.gigaflow"
CERTIFICATE_NAME = "GigaFlow Local Code Signing"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
SIGNING_DIR = Path.home() / "Library/Application Support/GigaFlow/Signing"


class SetupError(Exception):
    pass


def run(args: list[str], label: str, *, input_text: str | None = None) -> str:
    """Never echo command arguments or raw subprocess diagnostics (may be secret)."""
    try:
        result = subprocess.run(args, input=input_text, text=True, capture_output=True,
                                timeout=90, check=False)
    except subprocess.TimeoutExpired:
        raise SetupError(f"{label} timed out.") from None
    except OSError:
        raise SetupError(f"{label} could not start.") from None
    if result.returncode:
        raise SetupError(f"{label} failed (exit {result.returncode}).")
    return result.stdout


def write_new(path: Path, data: str, mode: int = 0o600) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def fingerprint(cert: Path) -> str:
    value = run([OPENSSL, "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1"],
                "Read certificate fingerprint")
    match = re.search(r"=\s*([0-9A-Fa-f:]+)\s*$", value)
    digest = match.group(1).replace(":", "").upper() if match else ""
    if not re.fullmatch(r"[0-9A-F]{40}", digest):
        raise SetupError("Certificate fingerprint is invalid.")
    return digest


def requirement(digest: str) -> str:
    return f'designated => identifier "{APP_IDENTIFIER}" and certificate leaf = H"{digest}"'


def validate_existing(metadata: Path, keychain: Path, password_file: Path, certificate: Path) -> dict:
    paths = [metadata, keychain, password_file, certificate]
    if any(not p.is_file() or p.is_symlink() for p in paths):
        raise SetupError("Established signing identity has missing or unsafe files; refusing to regenerate it.")
    if password_file.stat().st_mode & 0o077:
        raise SetupError("Signing password file permissions must be 0600; refusing to use it.")
    try:
        data = json.loads(metadata.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise SetupError("Identity metadata is unreadable; refusing to regenerate it.") from None
    digest = fingerprint(certificate)
    expected = {"certificate_sha1": digest, "designated_requirement": requirement(digest),
                "keychain_path": str(keychain)}
    if any(data.get(key) != value for key, value in expected.items()):
        raise SetupError("Identity metadata does not match the preserved certificate/keychain.")
    run([OPENSSL, "x509", "-in", str(certificate), "-noout", "-checkend", "0"],
        "Check certificate validity")
    found = run([SECURITY, "find-certificate", "-a", "-Z", str(keychain)],
                "Find existing signing certificate")
    if digest not in found.upper():
        raise SetupError("Preserved certificate is missing from its dedicated keychain.")
    # Avoid -v: system-wide certificate trust is distinct from a stable DR.
    identities = run([SECURITY, "find-identity", "-p", "codesigning", str(keychain)],
                     "Find existing signing identity")
    if digest not in identities.upper():
        raise SetupError("Preserved certificate has no matching signing identity in its keychain.")
    return expected


def setup() -> dict:
    if sys.platform != "darwin":
        raise SetupError("Run this setup on the Mac that owns GigaFlow.")
    os.umask(0o077)
    if SIGNING_DIR.is_symlink():
        raise SetupError("Signing directory must not be a symlink.")
    SIGNING_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if SIGNING_DIR.stat().st_mode & 0o077:
        raise SetupError("Signing directory permissions must be 0700.")
    metadata = SIGNING_DIR / "identity.json"
    keychain = SIGNING_DIR / "gigaflow-signing.keychain-db"
    password_file = SIGNING_DIR / "keychain-password.txt"
    certificate = SIGNING_DIR / "signing-cert.pem"
    marker = SIGNING_DIR / ".setup-in-progress"
    if metadata.exists():
        if marker.exists():
            raise SetupError("Setup marker remains next to an identity; inspect before proceeding.")
        return validate_existing(metadata, keychain, password_file, certificate)
    if any(SIGNING_DIR.iterdir()):
        raise SetupError("Signing setup is incomplete or the directory is occupied; refusing to generate a replacement identity.")

    # create-keychain may append to this list. Restore exactly, even after failure.
    before = shlex.split(run([SECURITY, "list-keychains", "-d", "user"], "Read keychain search list"))
    write_new(marker, "Incomplete setup: do not regenerate any established certificate.\n")
    password = secrets.token_hex(32)
    write_new(password_file, password + "\n")
    result = None
    cleanup_error = None
    try:
        with tempfile.TemporaryDirectory(prefix=".private-", dir=SIGNING_DIR) as temp_name:
            temp = Path(temp_name)
            os.chmod(temp, 0o700)
            private_key = temp / "private-key.pem"
            temporary_cert = temp / "certificate.pem"
            p12 = temp / "identity.p12"
            config = temp / "openssl.cnf"
            write_new(config, """[req]
prompt = no
distinguished_name = identity
x509_extensions = codesign
[identity]
CN = GigaFlow Local Code Signing
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
            run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
                 "-nodes", "-days", "3650", "-config", str(config), "-keyout", str(private_key),
                 "-out", str(temporary_cert)], "Generate local signing certificate")
            run([OPENSSL, "pkcs12", "-export", "-inkey", str(private_key), "-in", str(temporary_cert),
                 "-name", CERTIFICATE_NAME, "-out", str(p12), "-passout", "stdin"],
                "Package local signing identity", input_text=password + "\n")
            run([SECURITY, "create-keychain", "-p", password, str(keychain)], "Create dedicated signing keychain")
            run([SECURITY, "set-keychain-settings", "-l", "-u", "-t", "900", str(keychain)],
                "Configure dedicated keychain locking")
            run([SECURITY, "unlock-keychain", "-p", password, str(keychain)], "Unlock dedicated signing keychain")
            run([SECURITY, "import", str(p12), "-k", str(keychain), "-f", "pkcs12", "-P", password,
                 "-x", "-T", "/usr/bin/codesign"], "Import local signing identity")
            # Only this newly created keychain is touched; it contains one own key.
            run([SECURITY, "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-t", "private",
                 "-k", password, str(keychain)], "Authorize codesign for dedicated signing key")
            digest = fingerprint(temporary_cert)
            write_new(certificate, temporary_cert.read_text(encoding="ascii"))
            result = {"certificate_sha1": digest, "designated_requirement": requirement(digest),
                      "keychain_path": str(keychain)}
        # TemporaryDirectory removes both the raw PEM key and its encrypted P12.
    finally:
        if keychain.exists():
            try:
                run([SECURITY, "lock-keychain", str(keychain)], "Lock dedicated signing keychain")
            except SetupError as exc:
                cleanup_error = exc
        try:
            run([SECURITY, "list-keychains", "-d", "user", "-s", *before], "Restore keychain search list")
        except SetupError as exc:
            cleanup_error = exc
        if cleanup_error:
            raise cleanup_error
    if result is None:
        raise SetupError("Signing identity was not created.")
    write_new(metadata, json.dumps(result, indent=2) + "\n")
    marker.unlink()
    return validate_existing(metadata, keychain, password_file, certificate)


def main() -> int:
    try:
        data = setup()
    except SetupError as exc:
        print(f"Signing setup failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        # Do not expose subprocess arguments or secret contents in a traceback.
        print(f"Signing setup failed: {type(exc).__name__}; no identity was regenerated.", file=sys.stderr)
        return 1
    print(json.dumps({"status": "ready", **data}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
