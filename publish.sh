#!/bin/bash
cd "$(dirname "$0")"
export ANDROID_STORE_PASSWORD="$(pass android-store-password)"
export JAVA_HOME=/opt/android-studio/jbr
flutter build apk --release && ./android/gradlew -p android bundleRelease
echo ""
echo "AAB: build/app/outputs/bundle/release/app-release.aab"
