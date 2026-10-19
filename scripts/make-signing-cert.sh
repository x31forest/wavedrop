#!/bin/zsh
# One-time setup: creates a self-signed "Wavedrop Local Signing" code-signing certificate in your
# login keychain. build.sh signs with it when present, so macOS keeps Wavedrop's audio and
# Automation permissions across rebuilds (ad-hoc signatures change on every build).
#
# macOS asks for your login password once, to trust the certificate for code signing.
set -e
NAME="Wavedrop Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

OPENSSL=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout pass:wavedrop

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P wavedrop -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
# Let codesign use the key without a keychain dialog on every build (asks for your login password here).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -D "$NAME" -t private "$KEYCHAIN" >/dev/null

security find-identity -v -p codesigning | grep "$NAME"
echo "Done. Run ./build.sh — macOS will ask for Wavedrop's permissions one last time."
