#!/bin/bash
# Build a signed, package-spoofed backslashxx KernelSU manager.
#
# No manager *source* change is needed: a random applicationId comes from
# -PKSU_PACKAGE_NAME, the namespace stays me.weishu.kernelsu (so ksud's
# late_load restart path <package>/me.weishu.kernelsu.ui.MainActivity still
# resolves), and the APK is signed with your own key from gen-manager-key.sh.
#
# IMPORTANT: ksud is a separate Rust binary that the manager runs from
# nativeLibraryDir/libksud.so (see KsuCli.kt). The CI builds it in its own job
# and injects it; a plain `:app:assembleRelease` ships NO libksud.so, and the
# resulting manager shows empty modules and dead feature toggles. So we build
# ksud here with the SAME KSU_PACKAGE_NAME and drop it into jniLibs before
# assembling. Build the manager at the git tag that matches KSU_VERSION.
#
# Env:
#   KEY_ENV           key.env from gen-manager-key.sh            (required)
#   PKG               applicationId, keep stable across updates  (required)
#   REF               backslashxx/KernelSU git ref               (default: v3.3.0-51)
#   ABIS              space-separated, e.g. "arm64-v8a"          (default: arm64-v8a)
#   SRC               existing KernelSU checkout                 (default: clone fresh)
#   ANDROID_HOME, ANDROID_NDK_HOME, JAVA_HOME
set -euo pipefail

REF="${REF:-v3.3.0-51}"
ABIS="${ABIS:-arm64-v8a}"
: "${KEY_ENV:?set KEY_ENV to the key.env from gen-manager-key.sh}"
: "${PKG:?set PKG to a stable applicationId, e.g. aaaaaa.bbbbbb.cccccc}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
# SDK: platforms;android-37.0 build-tools;37.0.0 ndk;29.0.14206865 cmake;3.22.1 + JDK 21
# ksud build also needs rustup. KSU_PACKAGE_NAME bakes the pkg name into ksud.
export KSU_PACKAGE_NAME="$PKG"
source "$KEY_ENV"

abi_to_triple() { case "$1" in
  arm64-v8a) echo aarch64-linux-android;;
  armeabi-v7a) echo armv7-linux-androideabi;;
  x86_64) echo x86_64-linux-android;;
  *) echo "unknown abi: $1" >&2; return 1;; esac; }

WORK="${WORK:-$(mktemp -d)}"; SRC="${SRC:-$WORK/KernelSU}"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$REF" \
  https://github.com/backslashxx/KernelSU "$SRC"
cd "$SRC"

# 1) build ksud per ABI and drop it in as libksud.so
for abi in $ABIS; do
  triple="$(abi_to_triple "$abi")"
  rustup target add "$triple"
  # shellcheck disable=SC1091
  source .github/scripts/setup-rust-build.sh "$triple" 26
  LIBCLANG_PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib" \
    cargo build --release --target "$triple" --manifest-path ./userspace/ksud/Cargo.toml
  mkdir -p "manager/app/src/main/jniLibs/$abi"
  cp -f "target/$triple/release/ksud" "manager/app/src/main/jniLibs/$abi/libksud.so"
done

# 2) assemble + sign the manager
cd manager
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
chmod +x gradlew
./gradlew --no-daemon :app:assembleRelease \
  -PKSU_PACKAGE_NAME="$PKG" \
  -PKEYSTORE_FILE="$KEYSTORE_FILE" -PKEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
  -PKEY_ALIAS="$KEY_ALIAS" -PKEY_PASSWORD="$KEY_PASSWORD"

APK="$(find app/build/outputs/apk/release -name '*.apk' | head -1)"
echo "built: $APK"
unzip -l "$APK" | grep -q 'lib/.*/libksud.so' && echo "libksud.so embedded: OK" \
  || { echo "ERROR: libksud.so missing from APK" >&2; exit 1; }
"$ANDROID_HOME"/build-tools/37.0.0/apksigner verify -v "$APK" | grep -i "scheme v2"
