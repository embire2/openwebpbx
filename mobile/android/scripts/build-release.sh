#!/usr/bin/env bash
set -euo pipefail
: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK}"
: "${OPENWEB_ANDROID_KEYSTORE:?Set the private release keystore path}"
: "${OPENWEB_ANDROID_STORE_PASSWORD:?Set the private keystore password}"
: "${OPENWEB_ANDROID_KEY_PASSWORD:?Set the private key password}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
./gradlew --no-daemon :app:testDirectDebugUnitTest :app:testPlayDebugUnitTest :app:lintDirectRelease :app:lintPlayRelease :app:assembleDirectRelease :app:bundlePlayRelease :app:writeRuntimeInventory
version="$(python3 -c 'import json; print(json.load(open("app/build/outputs/apk/direct/release/output-metadata.json"))["elements"][0]["versionName"])')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Android version" >&2; exit 1; }
output_dir="${OPENWEB_ANDROID_OUTPUT_DIR:-$project_dir/../../artifacts/android}"
mkdir -p "$output_dir"
cp app/build/outputs/apk/direct/release/app-direct-release.apk "$output_dir/openwebpbx-$version-android.apk"
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "$output_dir/openwebpbx-$version-android.apk"
sha256sum "$output_dir/openwebpbx-$version-android.apk"

cp app/build/outputs/bundle/playRelease/app-play-release.aab "$output_dir/openwebpbx-$version-google-play.aab"
jarsigner -verify "$output_dir/openwebpbx-$version-google-play.aab"
sha256sum "$output_dir/openwebpbx-$version-google-play.aab"
