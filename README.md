# Tennanova

Android notification mirroring and clipboard sync for macOS. Personal, local-only,
no cloud account, no telemetry.

Two apps talk directly to each other over one TLS WebSocket on your LAN or through an
automatic local USB tunnel:

```
macOS (SwiftUI menu bar)  ◀── TLS/WSS ──▶  Android (Compose)
  NWListener + WebSocket                     NotificationListenerService
  Bonjour _tennanova._tcp                      hosts the socket
  UNUserNotificationCenter                   Accessibility clipboard capture
  bundled adb reverse                        public ClipboardManager APIs
  NSPasteboard                               ClipboardWriter
```

## What it does

- Android notifications appear in macOS Notification Center
- Reply from the Mac keyboard (via the notification's own `RemoteInput`)
- Invoke notification action buttons from the Mac
- Dismissing on one device dismisses on the other
- Clipboard text and one real image at a time sync both ways, including image files copied in Finder

Deliberately **not** included: screen mirroring, webcam, calls, SMS threads, or
generic/multi-file transfer.

## Requirements

| | |
|---|---|
| macOS | 14+, Apple silicon |
| Android | 13+ (minSdk 33) |
| Build | Swift 6.2 (Command Line Tools is enough — no Xcode), JDK 17+, Android SDK |

## Building

**Mac** — produces a signed `.app` bundle and packages the installed Android SDK `adb`
for automatic USB tunnelling. `UNUserNotificationCenter` refuses to work from a bare
executable, so use the script rather than `swift run`:

```bash
cd mac && ./make-app.sh && open build/TennaNova.app
```

**Android**:

```bash
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew installDebug
```

**Tests**:

```bash
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew testDebugUnitTest
cd ../mac && ./test.sh
```

## Setup

1. Launch the Mac app — it appears in the menu bar and shows a pairing QR.
2. Tap **Scan pairing code** on Android. Google Code Scanner needs no camera permission.
3. Android opens the system **notification access** confirmation if it is still missing.
4. Android then opens the system **Accessibility** confirmation for clipboard sync if it is
   still missing. Returning from each Settings screen automatically continues setup.

Those are one-time Android grants. There is no Shizuku app, daemon, wireless-debugging
pairing, privileged bridge, or post-reboot privilege setup.

### Hotspots

Either direction works, with no cable and no re-pairing:

- **Phone hotspot, Mac joins it.** The Mac picks up an address on the tether subnet that
  neither device has seen before.
- **Mac Internet Sharing, phone joins it.** That Wi-Fi has no internet, so Android keeps
  cellular as its default network.

Three things make that work. The Mac advertises *every* address it answers on — in the QR
and again on every connection — so the phone's list follows the Mac between networks. The
phone binds each attempt to the network whose own subnet contains the address, which is
what reaches a Wi-Fi with no internet. And when nothing known answers, the phone probes its
directly-connected subnets for the port, which is the only way to find a Mac that has just
joined the hotspot. mDNS cannot help here: it runs on the phone's default network, which
stays cellular while tethering.

The first connection on a new hotspot costs the ~3 s probe; after that the address is
remembered. The menu bar lists the addresses currently being advertised.

### If the phone can't reach the Mac

This network (`192.168.210.0/24`) has **AP client isolation** switched on, so the router
blocks device-to-device traffic. Leave the authorized phone connected by USB: the Mac app
detects exactly one connected Tennanova phone and maintains
`adb reverse tcp:18777 tcp:18777` automatically, including after detach/reattach.

The QR advertises the secured USB loopback endpoint as well as the LAN addresses. Android
tries USB first and falls back to LAN. USB debugging must already be enabled and this Mac
must be authorized on the phone; that is normally already true when personally sideloading
the app. For untethered use, disable AP/client isolation or use a hotspot.

### Pairing from the terminal

Faster than retyping base64 on a phone keyboard. Note the nested quotes — the *device*
shell strips unprotected double quotes and the JSON arrives malformed:

```bash
adb shell am start -n com.tennanova/.ui.MainActivity --es pair "'$(cat payload.json)'"
```

## How phone → Mac clipboard capture works

Android does not grant an Accessibility service a direct clipboard exemption. Tennanova's
narrowly scoped service listens for copy-related event metadata without retrieving the UI
tree. After an explicit copy action, and only while an authenticated Mac session exists, it
briefly adds a transparent 1×1 non-touchable Accessibility overlay. That gives Tennanova the
application focus Android requires for one `ClipboardManager.primaryClip` read; the overlay
is removed immediately.

- Text, URLs and OTPs use the normal text clip path.
- Single images use the clip's normal `content://` URI and `ContentResolver`; payload size and
  SHA-256 are verified before sending.
- Content fingerprints and sequence numbers suppress Mac ↔ phone echoes.
- **Share → Tennanova** is the fallback for apps whose copy action exposes no usable event.
- Capture only runs while authenticated and remains unavailable while the phone is locked.
- Mac → Android clipboard writes need no Accessibility access.

This is intended for a personally sideloaded app. Distribution through Google Play would
need a separate Accessibility policy review and clear in-app disclosure.

## Notes and known limits

- macOS shows **Tennanova's** icon as the notification icon; the Android app's icon can
  only be an attachment thumbnail. Same limitation as AirSync and LinkMyMac. Because that
  thumbnail is the only place a card can name its app, it holds the app icon, and cards
  read *contact → message* with no app label wedged in between. A group chat adds the
  chat name as a subtitle. The sender's photo is still sent but is not displayed.
- macOS has no callback for a user-*dismissed* notification, so dismissal is detected by
  polling `getDeliveredNotifications()` every 2s.
- The Mac's TLS cert uses **RSA, not EC**: `SecPKCS12Import` *crashes* with an uncaught
  `NSException` on EC keys on macOS 27. Verified experimentally, not a guess.
- Pinning hashes the **PKCS#1 RSAPublicKey**, because that is what Apple's
  `SecKeyCopyExternalRepresentation` returns — *not* the X.509 SubjectPublicKeyInfo that
  Java's `getEncoded()` gives. `CertPinning.kt` unwraps the SPKI to match. Verified to
  produce byte-identical output on both sides.

## Layout

```
protocol/PROTOCOL.md   wire format — the contract, change both apps together
mac/                   SwiftPM package + make-app.sh
android/               Gradle project
```
