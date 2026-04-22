#!/bin/bash
cd "$(dirname "$0")"
export ANDROID_STORE_PASSWORD="$(pass android-store-password)"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
flutter build apk --release
ln -sf build/app/outputs/flutter-apk/app-release.apk app-release.apk
