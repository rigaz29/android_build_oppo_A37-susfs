#!/bin/bash
# Build a signed, package-spoofed backslashxx KernelSU manager.
#
# No manager source change is needed: a random applicationId comes from
# -PKSU_PACKAGE_NAME, the namespace stays me.weishu.kernelsu (so ksud's
# late_load restart path <package>/me.weishu.kernelsu.ui.MainActivity still
# resolves), and the APK is signed with your own key from gen-manager-key.sh.
# Build the manager at the git tag that matches the kernel's KSU_VERSION.
#
# Env:
#   KEY_ENV     path to key.env from gen-manager-key.sh      (required)
#   PKG         applicationId to build under                 (required, keep stable across updates)
#   REF         backslashxx/KernelSU git ref                 (default: v3.3.0-51)
#   SRC         existing KernelSU checkout to build from      (default: clone fresh)
#   ANDROID_HOME, JAVA_HOME
set -euo pipefail

REF="${REF:-v3.3.0-51}"
: "${KEY_ENV:?set KEY_ENV to the key.env from gen-manager-key.sh}"
: "${PKG:?set PKG to a stable applicationId, e.g. aaaaaa.bbbbbb.cccccc}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
# SDK needs: platforms;android-37.0  build-tools;37.0.0  ndk;29.0.14206865  cmake;3.22.1
source "$KEY_ENV"

WORK="${WORK:-$(mktemp -d)}"; SRC="${SRC:-$WORK/KernelSU}"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$REF" \
  https://github.com/backslashxx/KernelSU "$SRC"
cd "$SRC/manager"
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
chmod +x gradlew
./gradlew --no-daemon :app:assembleRelease \
  -PKSU_PACKAGE_NAME="$PKG" \
  -PKEYSTORE_FILE="$KEYSTORE_FILE" -PKEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
  -PKEY_ALIAS="$KEY_ALIAS" -PKEY_PASSWORD="$KEY_PASSWORD"

APK="$(find app/build/outputs/apk/release -name '*.apk' | head -1)"
echo "built: $APK"
"$ANDROID_HOME"/build-tools/37.0.0/apksigner verify -v "$APK" | grep -i "scheme v2"
