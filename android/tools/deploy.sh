#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

cd "$ROOT"
./gradlew assembleDebug --no-daemon

APK="$ROOT/app/build/outputs/apk/debug/app-debug.apk"
echo "Installing $APK …"
adb install -r "$APK"
adb shell am start -n com.magicmaker.android/.MainActivity
echo "Done."
