#!/bin/sh
# Creates a self-signed code-signing certificate ("TV Extend Local Signing") in your login
# keychain, so every build of the Mac app has the same signature and macOS keeps its
# Screen Recording / Local Network permissions across rebuilds.
#
# Run once:   sh Tools/make-signing-cert.sh
# Undo:       security delete-identity -c "TV Extend Local Signing"
set -eu

NAME="TV Extend Local Signing"

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists in your keychain."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:tvextend -name "$NAME" 2>/dev/null

# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P tvextend -T /usr/bin/codesign

echo "Created \"$NAME\"."
security find-identity -p codesigning | grep "$NAME"
