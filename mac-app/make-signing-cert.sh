#!/bin/bash
# Run ONCE on your Mac:  bash mac-app/make-signing-cert.sh
# Makes a free, self-made code-signing certificate for TellyBeam and prints the two values
# to add as GitHub repo secrets (Settings > Secrets and variables > Actions):
#   MAC_SIGNING_P12       (the long text)
#   MAC_SIGNING_PASSWORD  (the password)
# After that, every build is signed the same way, so Macs keep TellyBeam's Screen
# Recording permission across updates. Keep the .p12 file somewhere safe; making a new
# one means everyone has to allow Screen Recording again once.
set -euo pipefail
NAME="TellyBeam Signing"
OUT="${1:-$HOME/TellyBeam-signing}"
mkdir -p "$OUT"
cd "$OUT"
PASSWORD="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout key.pem -out cert.pem \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# -legacy keeps the file readable by macOS's keychain (OpenSSL 3 defaults differ)
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" \
  -out TellyBeam-signing.p12 -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
       -out TellyBeam-signing.p12 -passout "pass:$PASSWORD"
rm key.pem
echo
echo "Saved $OUT/TellyBeam-signing.p12"
echo
echo "GitHub secret MAC_SIGNING_PASSWORD:"
echo "$PASSWORD"
echo
echo "GitHub secret MAC_SIGNING_P12 (copied to your clipboard too):"
base64 < TellyBeam-signing.p12 | tr -d '\n' | tee >(pbcopy 2>/dev/null || true)
echo
