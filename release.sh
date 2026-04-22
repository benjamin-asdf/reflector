#!/bin/bash
cd "$(dirname "$0")"
export ANDROID_STORE_PASSWORD="$(pass android-store-password)"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
flutter build appbundle --release
ln -sf build/app/outputs/bundle/release/app-release.aab app-release.aab
