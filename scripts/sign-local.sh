#!/bin/bash
# Local development only: keep the same certificate across rebuilds without
# importing keys into the login keychain or changing system trust settings.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Usage: scripts/sign-local.sh /path/to/Brim.app}"
signing_directory="$PWD/.sense-signing"
keychain="$signing_directory/Sense.keychain-db"
if [[ ! -f "$keychain" ]]; then
  if [[ -d "$signing_directory" ]]; then
    echo 'Local signing setup is incomplete. Preserve this folder and inspect it before retrying; do not rotate the identity silently.' >&2
    exit 1
  fi
  umask 077
  mkdir "$signing_directory"
  /usr/bin/openssl rand -hex 32 > "$signing_directory/password"
  cat > "$signing_directory/certificate.conf" <<'CONFIG'
[req]
distinguished_name = identity
x509_extensions = signing
prompt = no
[identity]
CN = Sense Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
  /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -config "$signing_directory/certificate.conf" \
    -keyout "$signing_directory/key.pem" -out "$signing_directory/certificate.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -name 'Sense Local Development' \
    -inkey "$signing_directory/key.pem" -in "$signing_directory/certificate.pem" \
    -out "$signing_directory/identity.p12" -passout "file:$signing_directory/password"
  signing_password="$(cat "$signing_directory/password")"
  /usr/bin/security create-keychain -p "$signing_password" "$keychain"
  /usr/bin/security unlock-keychain -p "$signing_password" "$keychain"
  /usr/bin/security import "$signing_directory/identity.p12" -k "$keychain" \
    -P "$signing_password" -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$signing_password" "$keychain" >/dev/null
  rm "$signing_directory/key.pem" "$signing_directory/identity.p12"
fi
signing_password="$(cat "$signing_directory/password")"
/usr/bin/security unlock-keychain -p "$signing_password" "$keychain"
identity="$(/usr/bin/openssl x509 -in "$signing_directory/certificate.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')"
# securityd must see a custom keychain in the search list even when codesign
# receives --keychain. Restore the exact prior list on both success and failure.
python3 - "$app" "$keychain" "$identity" <<'PY_SIGN'
import shlex
import subprocess
import sys
app, keychain, identity = sys.argv[1:]
security = "/usr/bin/security"
previous = shlex.split(subprocess.check_output([security, "list-keychains", "-d", "user"], text=True))
try:
    subprocess.run([security, "list-keychains", "-d", "user", "-s", *previous, keychain], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--timestamp=none", "--keychain", keychain,
                    "--sign", identity, app], check=True)
finally:
    subprocess.run([security, "list-keychains", "-d", "user", "-s", *previous], check=True)
PY_SIGN
/usr/bin/codesign --verify --strict "$app"
