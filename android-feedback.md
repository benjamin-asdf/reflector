# Edge-to-edge may not display for all users

**Status:** Needs fix

App targets SDK 36 (via Flutter defaults), so edge-to-edge is enforced on Android 15+. Currently `MainActivity.kt` is a bare `FlutterActivity()` subclass with no inset handling.

**Fix:** `SafeArea` is not used anywhere in the codebase. Wrap top-level screens with `SafeArea` to prevent content from rendering behind system bars (status bar, navigation bar) on Android 15+.


# Your app uses deprecated APIs or parameters for edge-to-edge

**Status:** Fixed

No deprecated edge-to-edge APIs in app code. The warning came from `flutter_audio_capture_local` which had outdated build settings.

**Done:** Updated `flutter_audio_capture_local/android/build.gradle`:
- compileSdk 34 -> 36
- Kotlin 1.7.10 -> 1.9.22
- Gradle plugin 3.5.0 -> 8.1.0
- Java 1.8 -> 17
- minSdk 21 -> 24 (match app)
- `lintOptions` -> `lint` (non-deprecated API)
- `kotlin-stdlib-jdk7` -> `kotlin-stdlib`


# "App not available for device"

**Status:** Likely not an SDK version issue

- `minSdkVersion` is 24 (Android 7.0) via Flutter defaults — this covers ~97% of devices
- `flutter_audio_capture_local` has `minSdkVersion 21`, so it's not raising the floor
- No `<uses-feature>` restrictions found in AndroidManifest.xml

**Likely causes:**
- Regional/country availability settings in Play Console
- Device exclusions set in Play Console under "Device catalog"

**Next steps:**
- Check Play Console > "Device catalog" for excluded devices
- Check Play Console > "Release" > "Countries/regions" for availability
- If specific devices are reported, check their specs against app requirements
