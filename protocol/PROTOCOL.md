# Tennanova wire protocol v1

Single source of truth for messages exchanged between the macOS app and the Android app.
Both implementations must be changed together when this file changes.

## Transport

- **Mac is the server**, Android is the client. The phone roams; the Mac doesn't.
- One **TLS 1.2+ WebSocket** connection carries everything.
- **Text frames** = UTF-8 JSON control messages (below).
- **Binary frames** = app icon or clipboard-image bytes, always preceded by the matching
  `icon.data` or `clip.image` text header.
- WebSocket ping/pong provides keepalive. The Android client pings every 20s and reconnects
  with bounded single-flight backoff when the connection fails.
- When the QR advertises `usbPort`, Android first connects to `127.0.0.1:usbPort`. The Mac
  app maintains the corresponding local `adb reverse` tunnel. A failed USB endpoint falls
  through to the LAN endpoints before reconnect backoff begins.
- The Mac reports **every** address it answers on, and Android walks the whole list. One
  address is not enough: on a hotspot the Mac's useful address is on the tether or
  `bridge` interface, and neither side can tell in advance which network is live. Connect
  timeouts are short (3s LAN, 1s USB) precisely because most of the list will be stale.
- Android binds each attempt to the `Network` whose own subnet contains the target, and
  leaves it unbound when no network matches. Without that, a Mac sharing its connection
  over Wi-Fi is unreachable: that Wi-Fi has no internet, Android keeps cellular as the
  default network, and unbound sockets leave by the wrong interface.

## Discovery

- Mac publishes Bonjour service `_tennanova._tcp` on the local network.
- Android resolves it with `NsdManager`.
- The pairing QR embeds literal `host:port` addresses so pairing still works where mDNS is blocked.
- Discovery can relocate only the disconnected LAN endpoint after DHCP changes. The optional
  USB loopback endpoint remains independent.
- **mDNS does not work while the phone is tethering.** `NsdManager` runs on the phone's
  default network, which stays cellular, and the tether interface has no `Network` object
  at all. When every known address has failed without a single connection, Android probes
  its directly-connected subnets (`/23` or narrower, ≤640 addresses, 400 ms each, at most
  once per 30 s) for the port. That is the only way to find a Mac that has just joined the
  hotspot with an address nobody has ever seen. A probe hit proves nothing on its own —
  the pin below still has to match before any session data moves.

## Pairing

1. On first launch the Mac generates a self-signed **RSA 2048** certificate (10y) and stores the
   PKCS#12 in the login Keychain.
   > EC keys are **not** usable here: `SecPKCS12Import` *crashes* (uncaught `NSException`,
   > not an error return) on EC keys on macOS 27. Verified. Use RSA.
2. The Mac displays a QR containing:
   ```json
   {"v":1,"host":"192.168.1.42","hosts":["192.168.1.42","192.168.43.37"],"port":18777,"usbPort":18777,"spki":"<base64 SHA-256 of server public key>","token":"<32-byte base64 one-time pairing token>"}
   ```
   `usbPort` and `hosts` are optional and additive within protocol v1. `usbPort` advertises
   the Android loopback port only; `host` and `port` always remain a LAN endpoint. `hosts`
   lists every address the Mac answers on, best first, and always repeats `host` as its
   first entry so an older phone build reading only `host` still pairs.
3. Android pins `spki` with a custom `X509TrustManager` — it trusts that key and nothing else.
   A pin mismatch is **fatal**: do not retry, surface it. (On macOS the connection reports
   `.waiting`, not `.failed`, on pin mismatch — treat it as fatal explicitly or it retries forever.)
4. Android sends `hello` carrying the one-time `token`. The Mac replies `hello.ack` with a
   long-lived `deviceToken` used for all later reconnects. The pairing token is then discarded.

## Message envelope

Every message is a JSON object with at least:

```jsonc
{"v": 1, "type": "<name>"}
```

`v` is the protocol version. A peer receiving an unknown `v` must refuse the session and say so,
rather than guessing.

## Messages

### Session

```jsonc
// Android -> Mac, first message on every connection
{"v":1,"type":"hello","token":"<pairing token, first time only>",
 "deviceToken":"<long-lived token, subsequent connections>",
 "device":{"id":"stable-uuid","name":"Pixel 9","model":"Pixel 9","androidSdk":35,"battery":82},
 "capabilities":["clip.image.v1"]}

// Mac -> Android
{"v":1,"type":"hello.ack","ok":true,"deviceToken":"<issued on first pair>",
 "macName":"Daniel's MacBook","hosts":["192.168.1.42","192.168.43.37"],"port":18777,
 "usbPort":18777,"capabilities":["clip.image.v1"]}

// Mac -> Android, the address list changed mid-session (it joined a hotspot, say),
// or the USB tunnel came up or went away.
// Optional and ignorable: a phone that skips it simply keeps the hello.ack list.
{"v":1,"type":"mac.hosts","hosts":["192.168.1.42","192.168.43.37"],"port":18777,
 "usbPort":18777}

// Mac -> Android, refusal (bad token, version mismatch)
{"v":1,"type":"hello.nack","reason":"bad_token|version_mismatch"}

// Android -> Mac, optional state refresh (battery is also present in hello)
{"v":1,"type":"device.state","battery":74,"charging":true,"dnd":false}
```

`usbPort` is authoritative in exactly the same way `hosts` is: present means the `adb reverse`
tunnel is up, **absent means there is no USB tunnel right now** — not "unchanged". It has to
travel on the wire and not only in the pairing QR, because the tunnel normally comes up *after*
pairing: a phone is plugged in once it is already paired. A QR-only `usbPort` means a phone
paired while unplugged can never learn the USB endpoint, which on a network with AP client
isolation leaves it with no route to the Mac at all.

That still leaves the case where the phone cannot establish any session to be told. So when the
phone has no known `usbPort`, it appends `127.0.0.1:port` to its candidate list as the **last**
entry, after every real address has failed. That costs one 1s timeout only in the situation
where nothing else works.

`hosts` is the Mac's complete account of where it can be reached, so the phone **replaces**
its list with it rather than merging — that is what stops dead addresses accumulating as
the Mac moves between networks. Whichever address the live session is on stays at the front.
Addresses from mDNS or from a subnet probe are merged in instead, since those are hints
rather than the whole truth.

### Notifications

```jsonc
// Android -> Mac
{"v":1,"type":"notif.posted",
 "key":"0|com.whatsapp|1234|null|10123",   // StatusBarNotification.key, opaque, the identity
 "pkg":"com.whatsapp",
 "appLabel":"WhatsApp",
 "iconHash":"ab12cd…",                      // sha256 of the app icon PNG
 "avatarHash":"ef34ab…",                    // optional, sha256 of the sender's photo PNG
 "title":"Sam",
 "body":"are you close?",
 "when":1723900000000,
 "category":"msg",
 "senderName":"Sam",                        // optional, from MessagingStyle
 "conversationTitle":"Sam",                 // optional, the chat this belongs to
 "resync":true,                             // optional, present only on a reconnect replay
 "actions":[{"id":0,"label":"Reply","isReply":true},
            {"id":1,"label":"Mark as read","isReply":false}]}

// Android -> Mac, notification gone from the phone
{"v":1,"type":"notif.removed","key":"…"}

// Mac -> Android, user typed a reply into Notification Center
{"v":1,"type":"notif.reply","key":"…","actionId":0,"text":"on my way"}

// Mac -> Android, user clicked a non-reply action button
{"v":1,"type":"notif.action","key":"…","actionId":1}

// Mac -> Android, user dismissed it on the Mac
{"v":1,"type":"notif.dismiss","key":"…"}
```

**Android sending rules** — these exist to stop duplicates and noise:
- Skip `FLAG_GROUP_SUMMARY` (the single biggest source of duplicate notifications).
- Skip `FLAG_ONGOING_EVENT` and foreground-service notifications.
- Skip Tennanova's own notifications (feedback loop).
- Skip packages the user has muted in settings.
- Prefer `EXTRA_BIG_TEXT` over `EXTRA_TEXT` for the body; fall back to `EXTRA_TEXT_LINES`.
- After `hello.ack` the phone replays every active notification so a fresh Mac is complete.
  Those carry `"resync":true`, and the Mac shows one only if it has never shown it before —
  otherwise a flapping socket would re-alert cards the user has already read.

**How the Mac draws a card** — thumbnail, then `senderName ?? title ?? appLabel`, then
`conversationTitle` when it differs from that title, then `body`. The app label is
deliberately *not* placed between the sender and the message: the thumbnail is the app
icon, so the name would only repeat what the picture already says. It survives as the
title only when a notification carries nothing better.

**Avatars** — `avatarHash` is the sender's photo, taken from the notification's
MessagingStyle person or its large icon. It travels over the same `icon.request` /
`icon.data` pair as `iconHash`; that channel is just hash-to-PNG and does not care what the
picture is of. The Mac currently does not display it: macOS always draws Tennanova's own
icon in the card header, so the attachment thumbnail is the only place a card can say which
app it came from, and that job goes to `iconHash`. Neither hash is part of the Mac's
duplicate fingerprint: a picture that arrives after the card was shown must never make the
next notification alert twice.

### App icons

Icons are content-addressed by hash so each one crosses the wire once, ever.

```jsonc
// Mac -> Android, "I don't have this icon cached"
{"v":1,"type":"icon.request","hash":"ab12cd…"}

// Android -> Mac, immediately followed by ONE binary frame with the PNG bytes
{"v":1,"type":"icon.data","hash":"ab12cd…","bytes":4096}
```

The Mac caches to `~/Library/Caches/com.tennanova.mac/icons/<hash>.png`.

### Clipboard

```jsonc
// either direction
{"v":1,"type":"clip.update","format":"text","body":"…","origin":"android|mac","seq":41}
```

Peers advertise `clip.image.v1` before either side sends images. An image header is
immediately followed by one binary frame of exactly `bytes` bytes:

```jsonc
{"v":1,"type":"clip.image","origin":"android|mac","seq":42,
 "mime":"image/png","bytes":145281,"sha256":"<lowercase hex>","name":"shot.png"}
```

- One image is transferred at a time; generic files and multi-item clips are not supported.
- Image payloads are capped at 25 MiB. Sources above that are optimized before sending.
- Receivers validate the advertised length and SHA-256 before publishing the image clipboard.
- Android publishes received images as a scoped `content://` stream rather than a filename.

- `origin` + `seq` identify clipboard events. Receivers combine those fields with content hashes,
  pasteboard change counts, or URI fingerprints to suppress echoes.
- Text remains compatible with peers that do not advertise image capability.
- **Mac → Android needs no Android permission** — `OP_WRITE_CLIPBOARD` is unconditional in AOSP.
- **Android → Mac requires Tennanova's one-time Accessibility grant.** The service detects an
  explicit copy signal, briefly owns a non-touchable Accessibility overlay to satisfy Android's
  focused-UID clipboard rule, reads one clip through public APIs, and removes the overlay.
- Accessibility is not a direct clipboard exemption. Capture is disabled unless the session is
  authenticated, and **Share → Tennanova** is the fallback when an app exposes no copy signal.
- Clipboard does not sync while the phone is locked (`isDeviceLocked` short-circuits reads in
  `ClipboardService`). This is expected, not a bug.

## Versioning

Additive fields are fine within `v:1` — receivers must ignore unknown keys. Any change to the
meaning of an existing field, or any new message type that the peer must understand to behave
correctly, requires bumping `v`.
