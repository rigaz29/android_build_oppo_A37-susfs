#!/bin/bash
# Generate a private signing key for the package-spoofed manager and print the
# two constants the kernel needs (see patches/spoof/0001-*.patch).
#
# The key must be RSA-2048: the kernel's check_v2_signature caps the signer
# cert at CERT_MAX_LENGTH = 1024 bytes, and an RSA-4096 cert (~1338 B) is
# rejected "cert length overlimit".
#
# keytool makes a PKCS12 store even for a .jks name, and PKCS12 has no separate
# key password, so the key password is forced equal to the store password.
#
# Output: <outdir>/manager.jks plus key.env. Keep both private; never commit.
set -euo pipefail

OUT="${1:-./manager-key}"
ALIAS="${ALIAS:-manager}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
mkdir -p "$OUT"; cd "$OUT"

PASS="$(openssl rand -hex 24)"
"$JAVA_HOME/bin/keytool" -genkeypair -v \
  -keystore manager.jks -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=A37 KernelSU Manager, O=a37, C=ID" >/dev/null

cat > key.env <<EOF
KEYSTORE_FILE=$(pwd)/manager.jks
KEYSTORE_PASSWORD=$PASS
KEY_ALIAS=$ALIAS
KEY_PASSWORD=$PASS
EOF
chmod 600 manager.jks key.env

"$JAVA_HOME/bin/keytool" -exportcert -keystore manager.jks -alias "$ALIAS" \
  -storepass "$PASS" 2>/dev/null > cert.der
SIZE=$(stat -c%s cert.der); HASH=$(sha256sum cert.der | cut -d' ' -f1)
[ "$SIZE" -le 1024 ] || { echo "cert $SIZE B > 1024 (CERT_MAX_LENGTH); use RSA-2048" >&2; exit 1; }
printf '\nAdd this pair to is_manager_apk (patches/spoof/0001-*.patch):\n'
printf '  check_v2_signature(path, 0x%x, "%s")\n' "$SIZE" "$HASH"
