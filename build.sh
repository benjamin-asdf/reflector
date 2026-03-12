#!/bin/bash
cd "$(dirname "$0")"
export ANDROID_STORE_PASSWORD="$(pass android-store-password)"
flutter build apk --release
