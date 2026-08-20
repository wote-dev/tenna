<div align="center">

<img src="assets/icon/generated/icon-square.png" width="120" alt="Tennanova">

# Tennanova

**Your Android phone's notifications, messages, calls and clipboard, on your Mac.**
Local-only. No account, no cloud service, no telemetry.

[![CI](https://github.com/wote-dev/tenna/actions/workflows/ci.yml/badge.svg)](https://github.com/wote-dev/tenna/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Android 13+](https://img.shields.io/badge/Android-13%2B-3ddc84)

</div>

Two apps talking directly to each other over one pinned TLS WebSocket: on your LAN, through a
USB tunnel, or through a relay that can only see ciphertext.

```
macOS (SwiftUI, menu bar + window)  ◀── TLS/WSS ──▶  Android (Compose)
  NWListener hosts the socket                          NotificationListenerService
  Bonjour _tennanova._tcp                              SMS provider + SmsManager
  UNUserNotificationCenter                             CallStyle notification intents
  NSPasteboard                                         ClipboardManager
  bundled adb reverse                                  hosts nothing; always the client
```

---

## What it does

- **Notifications** from the phone appear in macOS Notification Center and in the app window.
- **Reply from the Mac keyboard** through the notification's own reply field, so the message
  goes out via WhatsApp, Signal, Telegram or whatever posted it.
- **Action buttons** from the notification work from the Mac too.
- **Dismissing on one device dismisses on the other.**
- **Real SMS conversations** with full thread history, and sending to any number.
- **Calls ring on the Mac.** Answer, decline and hang up from there. Cellular calls and app
  calls like WhatsApp and Signal go through one code path.
- **Clipboard sync both ways:** text and one image at a time, including image files copied in
  Finder.
- A Mac window that keeps **Messages** and **Notifications** in separate lists, plus a Calls
  pane.

### What it deliberately doesn't do

Each of these is a decision, not a backlog item:

| Not included | Why |
|---|---|
| **Call audio** | Android does not let any third-party app capture voice-call audio. `CAPTURE_AUDIO_OUTPUT` is privileged, and the accessibility workaround was closed in 2022. The Mac is a control surface; the sound stays on the phone. Every screen with a call button says so. |
| **Mute during a call** | Needs an `InCallService`, which needs the default-dialer role. A button that silently does nothing is worse than no button. |
| **Screen mirroring, webcam** | Different problem, different app. |
| **Generic or multi-file transfer** | The clipboard carries one image at a time on purpose. A file manager is a different product. |
| **MMS** | The SMS provider gives text threads without the app being the default SMS app. MMS does not. Out of scope rather than half-supported. |

---

## Try it

The phone app is in this repo as **[`Tennanova.apk`](Tennanova.apk)**, built from the current
source. Install it with `adb install Tennanova.apk`, or copy it to the phone and open it. It is
arm64-only and signed with the standard Android debug key, which is fine for sideloading onto
your own phone and is the reason it is not a Play Store build.

The Mac app has to be built. It is signed **ad-hoc** (this project has no Apple Developer
account), so a downloaded `.app` would be blocked by Gatekeeper on arrival. That takes about
two minutes.

### What you need

| | |
|---|---|
| **macOS** | 14 or newer, Apple silicon |
| **Android** | 13 or newer (minSdk 33), sideloading enabled |
| **Swift** | 6.x. The **Command Line Tools are enough**; full Xcode is not required |
| **JDK** | 17 or newer |
| **Android SDK** | with `platform-tools` (for `adb`) |

If you have neither Xcode nor the Command Line Tools:

```bash
xcode-select --install
```

Gradle needs `JAVA_HOME` set explicitly. Which line works depends on where your JDK came from.
Homebrew's `openjdk` is keg-only, so `/usr/libexec/java_home` cannot see it:

```bash
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
```

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

```bash
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
```

Then the SDK, and a check that both are real before you build:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
```

```bash
"$JAVA_HOME/bin/java" -version && ls "$ANDROID_HOME/platform-tools/adb"
```

Put whichever pair works into your shell profile so they stick.

`android/local.properties` is gitignored, so a fresh clone has to supply the SDK path. Either
export `ANDROID_HOME` as above, or write the file:

```bash
echo "sdk.dir=$HOME/Library/Android/sdk" > android/local.properties
```

### 1. Build and run the Mac app

```bash
cd mac && ./make-app.sh && open build/TennaNova.app
```

Use the script, not `swift run`. `UNUserNotificationCenter` refuses to work from a bare
executable: it needs a real bundle with a bundle identifier, and a signature. `make-app.sh`
assembles the `.app`, signs it ad-hoc, bundles your SDK's `adb` for the USB tunnel, and
re-registers it with Launch Services so Notification Center picks up its icon.

The app appears in the Dock and the menu bar, and shows a pairing QR.

### 2. Install the Android app

Enable **Developer options → USB debugging** on the phone, plug it in, accept the
"Allow USB debugging?" prompt, and install the APK from this repo:

```bash
adb install Tennanova.apk
```

To build it yourself instead:

```bash
cd android && ./gradlew installDebug
```

### 3. Pair

1. On the phone, tap **Scan pairing code** and scan the QR from the Mac. This uses Google's
   Code Scanner, so it needs no camera permission of its own.
2. The phone opens the system **notification access** screen if that grant is missing.
3. Then the system **Accessibility** screen, for phone → Mac clipboard capture.

Returning from each Settings screen continues setup automatically. Both are one-time grants.
No Shizuku, no daemon, no wireless-debugging pairing, and nothing to redo after a reboot.

Two things on the phone's dashboard are switches rather than setup steps, because the app is
useful without either. **Text messages** is off until you turn it on, and asks for SMS and
contacts permissions at that point. **Calls** is already on and asks for nothing, because a
call is read from the notification your phone already shows for it.

<details>
<summary><b>Pairing from the terminal instead of scanning</b></summary>

Faster than retyping base64 on a phone keyboard. Note the nested quotes: the *device* shell
strips unprotected double quotes and the JSON arrives malformed.

```bash
adb shell am start -n com.tennanova/.ui.MainActivity --es pair "'$(cat payload.json)'"
```

</details>

### Running the tests

Swift Testing, on the Mac side:

```bash
cd mac && ./test.sh
```

JUnit, on the Android side:

```bash
cd android && ./gradlew testDebugUnitTest
```

`mac/test.sh` exists because the standalone Command Line Tools install `Testing.framework`
outside SwiftPM's default search path, so a bare `swift test` cannot find it. With full Xcode
installed, plain `swift test` works.

> Avoid `./gradlew connectedDebugAndroidTest` on a phone you have paired with. It uninstalls
> the app, which costs you the pairing.

---

## How it works

Each mechanism below is the short version, with the constraint that forced it. The wire format
itself (every message, every field, every edge case) lives in
**[protocol/PROTOCOL.md](protocol/PROTOCOL.md)**, the contract both apps are written against.

### The connection ladder

The Mac is always the server; the phone is always the client. The phone roams and the Mac does
not, so inverting that would mean the Mac chasing an address that changes every time the phone
leaves the house.

The phone tries, in order:

1. **USB:** `127.0.0.1:18777`, against an `adb reverse` tunnel the Mac maintains. 1s timeout.
2. **Every LAN address the Mac answers on**, best first. 3s timeout each.
3. **The relay**, last. 20s timeout, because the relay has to hand the stream to the Mac.

The order is the point: a Mac on the same desk is never reached by way of a server on another
continent.

The Mac advertises *all* of its addresses, and re-advertises whenever the list changes
mid-session. One address is not enough: on a hotspot the useful address is on a tether or
`bridge` interface, and neither side can tell in advance which network is live. Timeouts are
short precisely because most of the list will be stale.

The phone also **binds each attempt to the network** whose subnet contains the target. Without
that, a Wi-Fi with no internet is unreachable whenever Android keeps cellular or a VPN as the
default route, which is exactly the case when your Mac is sharing a connection.

### Pairing and trust

On first launch the Mac generates a self-signed **RSA 2048** certificate and keeps the PKCS#12
in a 0600 file under Application Support, with its password in a 0600 file beside it. The QR
carries the Mac's addresses, a SHA-256 of its public key, and a one-time pairing token. The
phone pins that key with a custom `X509TrustManager`, trusting that one key and nothing else,
sends the token, and gets back a long-lived device token for every reconnect afterwards. A pin
mismatch is fatal by design: it is surfaced, not retried.

Three findings worth keeping, because they cost real time:

- **RSA, not EC.** `SecPKCS12Import` *crashes* on EC keys on macOS 27 (uncaught `NSException`,
  not an error return). Verified experimentally.
- **The pin hashes the PKCS#1 `RSAPublicKey`**, because that is what Apple's
  `SecKeyCopyExternalRepresentation` returns, not the X.509 SubjectPublicKeyInfo that Java's
  `getEncoded()` gives. `CertPinning.kt` unwraps the SPKI to match, and the two sides were
  verified to produce byte-identical output.
- **Not the login keychain.** A `SecIdentity` only exists inside *some* keychain, and left to
  itself `SecPKCS12Import` picks the login one, where the item's ACL names the importing app's
  code signature. This app is ad-hoc signed, so every rebuild produced a new signature, a stale
  ACL, and a *"Tennanova wants to sign using key"* password dialog. It now imports into an
  app-owned keychain that never auto-locks, with an ACL that trusts all applications. See
  `mac/Sources/TennaNova/Server/TLSIdentity.swift`, and [SECURITY.md](SECURITY.md) for what
  that trade does and does not give away.

### Notifications, and replying to a conversation the phone has forgotten

Messaging apps withdraw their notification the moment you read the chat on the phone. By the
time you look at the Mac, most conversations have already been removed, but the reply is not
gone with them: an Android reply `PendingIntent` stays live until the *posting app* cancels it,
not when its notification is dismissed. So the phone keeps each notification's action list
after removal, and reports back what became of every reply it fires.

### Calls

A call is not read from a telephony API. It is read from the **notification** every calling app
must post for one. That single decision is what makes one code path cover the cellular dialer,
WhatsApp, Signal and Telegram alike, and it costs no permission beyond the notification access
the app already has.

`Notification.EXTRA_CALL_TYPE` says whether a call is ringing or in progress, and the
`CallStyle` answer, decline and hang-up `PendingIntent`s are what the Mac's buttons fire.
Pressing one from the Mac does exactly what pressing it on the phone does. For a dialer that
puts no buttons in its notification, the optional `ANSWER_PHONE_CALLS` grant lets
`TelecomManager` stand in. Calls still ring on the Mac without it, which is why the phone
reports that state as *limited* rather than as needing attention.

Calls never enter the message list. A call has no transcript and cannot be replied to, so it
gets a pane and a banner of its own.

### SMS

SMS is the one messaging surface Android actually opens to a third-party app. WhatsApp, Signal
and the rest expose nothing but their notifications, with no history and no way to start a
conversation, so a Mac-side chat for those can only ever be notification-shaped. The SMS
provider has no such limit: full thread history, and `SmsManager` sends to any number
**without** the app being the default SMS app. Only writing to the provider and MMS need that
role, and Tennanova does neither.

Contact names are resolved **on the phone**, which already holds `READ_CONTACTS` for it. That
is why there is no contacts protocol and no contact cache on the Mac.

### Clipboard

The two directions are not symmetric, and that asymmetry is the whole story.

**Mac → phone is free.** Writing the clipboard needs no Android permission at all.

**Phone → Mac needs the Accessibility grant**, because Android only lets the app holding
application focus read the clipboard. That is a foreground-only rule with no exemption for
Accessibility services. Tennanova's service watches for copy-related event metadata *without*
reading the UI tree; after an explicit copy, and only while an authenticated Mac session
exists, it briefly takes the focus Android requires for exactly one read, then gives it back.
Content fingerprints and sequence numbers on both ends stop a clip echoing back and forth.

- Capture only runs while authenticated, and never while the phone is locked.
- **Share → Tennanova** is the fallback for apps whose copy action exposes no usable signal.
- Images travel as a `content://` stream; length and SHA-256 are verified before publishing.

The full mechanism, including why the focus window has to be configured the way it is, is in
[PROTOCOL.md](protocol/PROTOCOL.md#clipboard).

> This is built for a personally sideloaded app. Distributing it through Google Play would
> require a separate Accessibility policy review and prominent in-app disclosure.

### The relay

Public, hotel and corporate Wi-Fi very often run **AP client isolation**: every packet from one
client to another is dropped at the access point. No LAN transport survives that, because the
block sits below the layer an app runs at, so no amount of mDNS or subnet probing changes it.
On one such network the Mac could see 45 neighbours in its ARP table, zero other Bonjour
services, and not one open TCP port among them.

Both devices can still reach the internet, so each dials *out* to a relay over `wss` on 443 and
it forwards bytes between them.

**The relay cannot see anything.** What it forwards is the phone's ordinary TLS session to the
Mac: the same one, pinned to the same key, negotiated end to end *through* the pipe. The relay
carries ciphertext it holds no key for. It can delay or drop a session; it cannot read one,
forge one, or authenticate as either device. Nothing in it parses, stores or logs a payload
byte. Neither app's protocol code even knows it exists, because each end runs a local loopback
pump.

A room is named `base64url(sha256(secret))`. The **Mac** holds the secret and is the only party
that can host the room; the **phone** is handed only the room id, so it can join but never
host. Knowing a room id buys someone a TCP pipe to the Mac's listener, exactly the exposure of
being on the same LAN, and the pinned certificate and pairing token still guard the session.

Builds default to a relay at `tennanova-relay.fly.dev`. That is **the author's own instance**,
run on a small Fly machine so a fresh clone has a working fallback. It is best-effort with no
uptime promise, it may be rate-limited or retired, and as above it cannot read a byte of what
it carries. **Run your own.** `relay/` deploys to Fly, Railway, Render or a VPS behind Caddy:

```bash
defaults write com.tennanova.mac relayHost my-relay.example.com
```

Or stay LAN and USB only, and never dial out at all:

```bash
defaults write com.tennanova.mac relayEnabled -bool NO
```

Serverless hosts will not work: a Tennanova session is meant to idle for hours, and
Vercel/Lambda-style functions cap request duration. See **[relay/README.md](relay/README.md)**.

---

## Privacy and permissions

Nothing needs an account. Nothing is uploaded. There is no analytics or crash-reporting SDK in
either app, and the only network destinations are your own Mac and, if you leave it enabled,
the relay, which carries ciphertext.

**What the Android app asks for:**

| Permission | What it enables | Optional? |
|---|---|---|
| Notification access | Everything: notifications, replies, and calls | Required |
| Accessibility | Phone → Mac clipboard capture only | Optional; everything else works without it |
| `READ_SMS` / `SEND_SMS` | SMS threads and sending | Optional; asked for only when you turn SMS on |
| `READ_CONTACTS` | Resolving numbers to names on the phone | Optional, with SMS |
| `ANSWER_PHONE_CALLS`, `READ_PHONE_STATE` | Answering a dialer whose notification carries no buttons | Optional; calls still ring without it |
| `INTERNET`, `ACCESS_NETWORK_STATE` | The socket itself | Required |

There is deliberately no `CAPTURE_AUDIO_OUTPUT` (privileged), no default-SMS-app role, and no
default-dialer role.

**What the Mac stores, and where:**

| | |
|---|---|
| TLS identity (PKCS#12) | `~/Library/Application Support/TennaNova/identity.p12`, imported into an app-owned keychain |
| Paired device, tokens, relay secret | `UserDefaults` for `com.tennanova.mac` |
| Conversation history | `~/Library/Application Support/com.tennanova.mac/history.json` |
| App icons | `~/Library/Caches/com.tennanova.mac/icons/` |

Unpairing from either device forgets the phone and deletes the conversations that came with it.

---

## Troubleshooting

**The phone can't reach the Mac at all.**
Almost always **AP client isolation**: the router is dropping device-to-device traffic. Three
ways out, in order of preference:

1. **USB.** Leave the phone connected. The Mac detects a single connected Tennanova phone and
   maintains `adb reverse tcp:18777 tcp:18777` automatically, including across detach and
   reattach. USB debugging must be enabled and this Mac authorized on the phone, which is
   normally already true if you sideloaded the app yourself.
2. **The relay**, which is what it exists for.
3. **Turn client isolation off** on the router, if it's yours.

**Hotspots.** Both directions work, with no cable and no re-pairing: phone hotspot with the Mac
joining it, or Mac Internet Sharing with the phone joining that. The first connection on a new
hotspot costs a ~3s probe while the phone searches its directly-connected subnets for a Mac at
an address nobody has seen before; after that the address is remembered. mDNS cannot help here,
because it runs on the phone's default network, which stays cellular while tethering.

**It connected before and now won't.** Check the menu bar: it lists the addresses currently
being advertised. If the Mac has moved networks, the phone follows on its own. A *pin mismatch*
never retries, by design. That means the Mac's TLS identity changed, from a deleted
`~/Library/Application Support/TennaNova/` or a different Mac, and the fix is to unpair on both
sides and scan a fresh QR.

**Starting over.** Unpair from the Mac's device pane or its menu bar, or from the phone's
dashboard. Either side mints a fresh pairing token and a new QR.

**macOS keeps asking for your keychain password.** The dialog reads *"Tennanova wants to sign
using key 'Imported Private Key'"*, typically after waking the Mac or after a rebuild. Builds
before this was fixed imported the TLS identity into your **login keychain** on every launch,
leaving one certificate and key per build behind, each with an ACL tied to a code signature
that no longer existed. Current builds keep the identity in a keychain of their own and clear
those leftovers out on first run, so updating and relaunching once is the whole fix.

An orphaned key whose certificate was already gone cannot be matched safely and is left alone.
To check, and to clear it by hand:

```bash
security find-certificate -a -c "TennaNova Mac" ~/Library/Keychains/login.keychain-db
```

If anything is still listed, open **Keychain Access → login → Certificates** and delete the
`TennaNova Mac` entries, plus any orphaned `Imported Private Key` beside them. Nothing there is
load-bearing: the identity the phone pins lives in
`~/Library/Application Support/TennaNova/identity.p12`, and pairing survives untouched.

**Logs.** The Mac:

```bash
log stream --predicate 'subsystem == "com.tennanova.mac"' --level debug
```

The phone:

```bash
adb logcat -s TennaNova:V TennaClipboard:V
```

---

## Repo layout

```
protocol/PROTOCOL.md   the wire format; the contract, change both apps together
mac/                   SwiftPM package, make-app.sh, test.sh
android/               Gradle project
relay/                 the blind byte pipe, and how to deploy your own
Tennanova.apk          the phone app, built from this source
assets/icon/           icon masters; every app icon is generated from these
tools/make-icons.sh    the generator
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers building, testing and the rule about changing the
wire format. [SECURITY.md](SECURITY.md) covers what the threat model does and does not include,
and how to report a vulnerability privately.

## Development

`protocol/PROTOCOL.md` is the single source of truth for anything crossing the wire. Additive
fields are fine within `v:1`, and receivers must ignore unknown keys. Changing what an existing
field *means*, or adding a message the peer must understand to behave correctly, requires
bumping the version. Both implementations change together.

Regenerating every launcher icon, the macOS `.icns` and the masked PNGs from the two masters
in `assets/icon/`, needed only when the artwork changes:

```bash
./tools/make-icons.sh
```

## Status

Pre-1.0, and built for sideloading onto your own phone. It is used daily on real hardware, but
on a small number of devices, so expect to meet a dialer or a launcher that behaves differently
from the ones it has seen. Bug reports that name the phone, the Android version and the app
involved are the useful kind.

Good places to contribute: dialers and messaging apps whose notifications are shaped
unexpectedly, network conditions the connection ladder doesn't handle, and anything in
`PROTOCOL.md` that turns out to be wrong.

## Notes and known limits

- macOS shows **Tennanova's** icon on a notification; the Android app's own icon can only be an
  attachment thumbnail. Same limitation as AirSync and LinkMyMac. Since that thumbnail is the
  only place a card can name its app, it holds the app icon, and cards read *contact →
  message* with no app label wedged in between. A group chat adds the chat name as a subtitle.
- macOS has no callback for a user-*dismissed* notification, so dismissal is detected by
  polling `getDeliveredNotifications()` every 2s.
- An incoming-call card cannot be a time-sensitive or critical alert, since both need Apple
  entitlements. It is an ordinary notification with a distinct sound, plus an in-window banner
  and a menu bar item that changes while the phone rings.
- The Mac's sidebar splits chats from app noise with the same test that groups them: a
  notification with a sender, a chat title, a `msg` category or a reply button is a
  conversation; everything transactional is one row per app under **Notifications**.

## License

MIT. See [LICENSE](LICENSE).
