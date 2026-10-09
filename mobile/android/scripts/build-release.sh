#!/usr/bin/env bash
set -euo pipefail
: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK}"
: "${OPENWEB_ANDROID_KEYSTORE:?Set the private release keystore path}"
: "${OPENWEB_ANDROID_STORE_PASSWORD:?Set the private keystore password}"
: "${OPENWEB_ANDROID_KEY_PASSWORD:?Set the private key password}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
./gradlew --no-daemon :app:testDebugUnitTest :app:lintRelease :app:assembleRelease
output_dir="${OPENWEB_ANDROID_OUTPUT_DIR:-$project_dir/../../artifacts/android}"
mkdir -p "$output_dir"
cp app/build/outputs/apk/release/app-release.apk "$output_dir/openwebpbx-1.0.5-android.apk"
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose --print-certs "$output_dir/openwebpbx-1.0.5-android.apk"
sha256sum "$output_dir/openwebpbx-1.0.5-android.apk"
