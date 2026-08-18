#!/bin/zsh
# Assembles TennaNova.app from the SwiftPM build.
#
# This exists because the machine has the Command Line Tools but not full Xcode.
# UNUserNotificationCenter refuses to work from a bare executable — it needs a real
# bundle with a bundle identifier, and it needs to be signed (ad-hoc is enough locally).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/TennaNova.app"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/TennaNova"
[[ -f "$BIN" ]] || { echo "no binary at $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TennaNova"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the Android SDK's universal platform-tools adb. It is used only to maintain
# the local USB reverse tunnel; it does not grant the Android app any privileges.
ADB=""
for CANDIDATE in \
  "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
  "${ANDROID_HOME:-}/platform-tools/adb" \
  "$HOME/Library/Android/sdk/platform-tools/adb" \
  "/opt/homebrew/bin/adb" \
  "/usr/local/bin/adb"; do
  if [[ -n "$CANDIDATE" && -x "$CANDIDATE" ]]; then
    ADB="$CANDIDATE"
    break
  fi
done

if [[ -n "$ADB" ]]; then
  mkdir -p "$APP/Contents/Resources/platform-tools"
  cp "$ADB" "$APP/Contents/Resources/platform-tools/adb"
  chmod 755 "$APP/Contents/Resources/platform-tools/adb"
  echo "==> bundled adb from $ADB"
else
  echo "warning: adb was not found; this build will use LAN only"
fi

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - \
         --identifier com.tennanova.mac \
         "$APP"

# Notification Center asks Launch Services for the icon of whatever posted a card, and it
# caches that answer per bundle id. Early builds registered com.tennanova.mac before the
# icon existed, which is why mirrored notifications drew a blank tile. Unregister first so
# the stale answer goes away, then re-register the current bundle.
echo "==> registering with Launch Services"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -f "$PWD/$APP" 2>/dev/null || true

# usernoted holds its own icon cache and will happily keep showing the old blank one.
killall usernoted 2>/dev/null || true

echo
echo "built $PWD/$APP"
echo "run it with:  open $PWD/$APP"
