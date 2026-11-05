#!/bin/bash
# Run once in the Mac's local GUI session so macOS can request authorization.
set -u
signing_dir="$HOME/Library/Application Support/GigaFlow/Signing"
printf 'GigaFlow: allow the local signing certificate for /usr/bin/codesign only.\n'
printf 'macOS may request your confirmation. No system-wide or network trust is added.\n\n'
if /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -a /usr/bin/codesign \
    -k "$signing_dir/gigaflow-signing.keychain-db" "$signing_dir/signing-cert.pem"; then
    printf 'approved\n' > "$signing_dir/trust-result.txt"
    printf '\nGigaFlow signing certificate approved. You can close this window.\n'
else
    printf 'not-approved\n' > "$signing_dir/trust-result.txt"
    printf '\nmacOS did not approve the change. The existing GigaFlow is unchanged.\n'
fi
