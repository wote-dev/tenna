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
- Android binds each freshly discovered attempt to the exact `Network` on which mDNS
  found it. Remembered literal addresses fall back to the `Network` whose own subnet
  contains the target, and stay unbound when no network matches. Without this, a local-only
  Wi-Fi is unreachable whenever Android keeps cellular or a VPN as the default route.
- When every direct route fails, the session falls back to the **relay** (`relay/`). Public
  and corporate Wi-Fi routinely run AP client isolation, which drops every packet between
  two clients of the same network; no LAN transport can survive that, because the block is
  enforced in the access point. Both devices instead dial out to a relay over `wss` on 443
  and it forwards bytes between them.

  The relay is a byte pipe and nothing more. It carries **this same TLS 1.2+ WebSocket
  session**, negotiated end to end through the pipe and still pinned to the Mac's public
  key, so the relay sees only ciphertext and cannot read, forge or authenticate a session.
  Neither side's protocol code knows the relay exists: each runs a local loopback pump, and
  the Mac's pumped stream terminates on its own ordinary listener.

  It is always tried **last**, after USB and every LAN address, so a Mac on the same desk
  is never reached by way of a server on another continent. Connect timeout is 20s, against
  3s for LAN and 1s for USB, because the phone must wait for the relay to hand the stream
  to the Mac.

## Discovery

- Mac publishes Bonjour service `_tennanova._tcp` on every local network. Its TXT record
  includes `spki`, allowing an already-paired phone to ignore other Tennanova Macs before
  connecting; TLS pinning remains the actual authentication check.
- Android uses the `NsdManager` `NetworkRequest` overload to browse every available
  `Network`, including local-only Wi-Fi, and retains the exact route with each result.
- The pairing QR embeds literal `host:port` addresses so pairing still works where mDNS is blocked.
- Discovery can relocate only the disconnected LAN endpoint after DHCP changes. The optional
  USB loopback endpoint remains independent.
- **The phone's own tether interface has no Android `Network` object**, so even all-network
  NSD cannot browse it. When every known address has failed without a single connection,
  Android probes
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
   {"v":1,"host":"192.168.1.42","hosts":["192.168.1.42","192.168.43.37"],"port":18777,"usbPort":18777,"spki":"<base64 SHA-256 of server public key>","token":"<32-byte base64 one-time pairing token>","relayHost":"tennanova-relay.fly.dev","relayRoom":"<base64url sha256 of the Mac's relay secret>"}
   ```
   `relayHost` and `relayRoom` are optional and additive within protocol v1. They name the
   Mac's relay and the room to ask for; `relayRoom` is `base64url(sha256(relaySecret))`, so
   the phone can join the room but never host it. Both appear only while the Mac's own
   relay control channel is up. A room id is not a credential: knowing one buys a TCP pipe
   to the Mac's listener, exactly the exposure of sharing its LAN, and the pinned
   certificate and pairing token still guard the session.

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
 "usbPort":18777,"relayHost":"tennanova-relay.fly.dev","relayRoom":"<base64url sha256 of the Mac's relay secret>",
 "capabilities":["clip.image.v1"]}

// Mac -> Android, the address list changed mid-session (it joined a hotspot, say),
// or the USB tunnel came up or went away.
// Optional and ignorable: a phone that skips it simply keeps the hello.ack list.
{"v":1,"type":"mac.hosts","hosts":["192.168.1.42","192.168.43.37"],"port":18777,
 "usbPort":18777,"relayHost":"tennanova-relay.fly.dev","relayRoom":"<base64url sha256 of the Mac's relay secret>"}

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

`relayHost` and `relayRoom` travel on the wire for the same reason as `usbPort`, but are
**merged, not replaced**: they are absent whenever the Mac's relay control channel is
momentarily down, and forgetting the relay at that exact moment would strip a phone of the
one route that survives a network which carries nothing between its own clients.

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

// Mac -> Android, user typed a reply into Notification Center or the window
{"v":1,"type":"notif.reply","key":"…","actionId":0,"text":"on my way",
 "clientId":"9F3B…"}                       // optional; echoed back in notif.reply.result

// Android -> Mac, what became of that reply. Requires notif.reply.offline.v1.
{"v":1,"type":"notif.reply.result","clientId":"9F3B…","key":"…","actionId":0,
 "ok":false,"error":"The app withdrew this conversation's reply."}

// Mac -> Android, user clicked a non-reply action button
{"v":1,"type":"notif.action","key":"…","actionId":1}

// Mac -> Android, user dismissed it on the Mac
{"v":1,"type":"notif.dismiss","key":"…"}
```

**Replying to a notification the phone no longer shows** — capability
`notif.reply.offline.v1`. Messaging apps withdraw their notification the moment the chat
is read on the phone, so by the time anyone looks at the Mac window nearly every
conversation has already been `notif.removed`. That does *not* mean the reply is gone: an
Android reply `PendingIntent` is not invalidated when its notification is cancelled, and
stays live until the posting app cancels the intent itself. A phone advertising this
capability therefore keeps each key's action list after removal (bounded, least-recently
used evicted first) instead of dropping it, and answers every `notif.reply` with a
`notif.reply.result`.

The Mac must not offer a composer for a removed conversation against a phone *without* the
capability — an older build has already thrown the actions away and would drop the reply in
silence. `ok:true` means the phone fired the intent, which is not proof the app accepted
it; only the phone mirroring the message back confirms that.

## SMS — capability `sms.v1`

The one messaging surface Android actually opens to a third-party app. WhatsApp, Signal and
the rest expose nothing but their notifications — no history, no way to start a
conversation — so a Mac-side chat for those can only ever be notification-shaped. The SMS
provider has no such limit: full thread history, and `SmsManager` sends to any number
*without* the app being the default SMS app. Only writing to the provider and MMS need that
role, and neither is done. **Text SMS only**; MMS is out of scope rather than half-supported.

Advertised only while the user has switched SMS on **and** granted `READ_SMS`/`SEND_SMS`, so
the Mac can tell "this build cannot" from "this phone has not been asked yet".

```jsonc
// Android -> Mac, the conversation list, after hello.ack
{"v":1,"type":"sms.threads","threads":[
  {"id":42,"address":"+61491570006","displayName":"Sam",
   "snippet":"see you at 8","when":1723900000000,"unread":3}]}

// Mac -> Android, open a conversation (beforeId pages further back)
{"v":1,"type":"sms.thread.request","threadId":42,"beforeId":991,"limit":100}

// Android -> Mac, one page, oldest first. complete=false means more history remains.
{"v":1,"type":"sms.messages","threadId":42,"complete":true,"messages":[
  {"id":992,"threadId":42,"address":"+61491570006","displayName":"Sam",
   "body":"are you close?","when":1723900000000,"outgoing":false,"read":true}]}

// Android -> Mac, one new message, pushed live by a ContentObserver
{"v":1,"type":"sms.received","message":{…}}

// Mac -> Android, send
{"v":1,"type":"sms.send","address":"+61491570006","body":"five minutes","clientId":"9F3B…"}

// Android -> Mac, what the radio said
{"v":1,"type":"sms.send.result","clientId":"9F3B…","ok":false,"error":"The phone's radio is off."}
```

`displayName` is resolved **on the phone**, which already holds `READ_CONTACTS` for it.
That is why there is no contacts protocol here and no contact cache on the Mac.

`outgoing` means "the user sent this", not "this device sent it": a text typed on the phone
and one typed on the Mac read identically in a transcript.

**Duplicate suppression, and the detail that would otherwise ruin this.** Every incoming
text raises both a provider row *and* a notification. While `sms.v1` is active the phone
must also drop notifications from `Telephony.Sms.getDefaultSmsPackage(context)` — the SMS
channel owns those conversations, and mirroring both shows every message twice.

Unlike `notif.reply`, an SMS really can reach `confirmed`: the provider row the phone writes
comes back as `sms.received` and reconciles the optimistic bubble by body and time.

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

## Calls — capability `call.v1`

**Android does not let a third-party app capture voice-call audio.** `CAPTURE_AUDIO_OUTPUT` is
privileged, and the accessibility workaround was closed in 2022. So the Mac is a *control
surface*: it rings, it names the caller, and it answers, declines and hangs up. The audio
stays on the phone or on whatever Bluetooth headset the phone is already using. Every
surface that offers a call button says so, rather than letting a user pick up on the Mac
and then wonder why the room is silent.

Calls arrive as **notifications**, not as a telephony API. That is deliberate and it is
what makes this work for WhatsApp, Signal and Telegram calls as well as cellular ones: a
call is the one thing every app on Android must post a notification for. It also costs no
permission at all — the notification listener is already granted.

`call.v1` is advertised while the user has calls switched on. `canAnswer` / `canDecline` /
`canHangUp` then say, per call, what this phone can actually do about *that* call, which is
not the same question: a notification carrying no answer intent on a phone without
`ANSWER_PHONE_CALLS` can be shown and not answered.

```jsonc
// Android -> Mac, on every change to a call. `ended` is the last one for that id.
{"v":1,"type":"call.state",
 "id":"0|com.samsung.android.dialer|1|null|1000", // opaque, stable for the call's life
 "state":"ringing|active|ended",
 "direction":"incoming|outgoing",
 "pkg":"com.samsung.android.dialer",
 "appLabel":"Phone",
 "iconHash":"ab12cd…",                 // optional, the app icon, same channel as notifications
 "avatarHash":"ef34ab…",                // optional, the caller's photo
 "displayName":"Sam",                   // optional, resolved on the phone
 "number":"+61491570006",               // optional
 "video":false,
 "when":1723900000000,
 "canAnswer":true, "canDecline":true, "canHangUp":false,
 "resync":true,                         // optional, present only on a reconnect replay
 "actions":[{"id":2,"label":"Message","isReply":false}]}

// Mac -> Android
{"v":1,"type":"call.action","id":"…","action":"answer|decline|hangup","clientId":"9F3B…"}

// Android -> Mac, what became of it
{"v":1,"type":"call.action.result","clientId":"9F3B…","id":"…","action":"answer",
 "ok":false,"error":"This phone cannot answer calls from the Mac yet."}
```

`actions` are the notification's *other* buttons — "Message", "Remind me". They are fired
with the existing **`notif.action`**, whose `key` is this call's `id`: a call's actions are
retained under the same key as any other notification's, so calls needed no second action
channel of their own.

Answer and decline are **not** in that list. They are resolved on the phone, in this order,
and `canAnswer`/`canDecline` report whether any of it will actually work:

1. `Notification.EXTRA_ANSWER_INTENT` / `EXTRA_DECLINE_INTENT` / `EXTRA_HANG_UP_INTENT` —
   the `CallStyle` intents. Present for anything built against API 31+, and they are the
   app's own buttons, so they do exactly what pressing them on the phone does.
2. `TelecomManager.acceptRingingCall()` / `endCall()`, which need the optional
   `ANSWER_PHONE_CALLS` grant and work only for calls Telecom manages — cellular ones, and
   VoIP apps that register a `ConnectionService`. This is the fallback for a dialer whose
   notification carries no intents.

There is deliberately no mute: muting a call needs an `InCallService`, which needs the
default-dialer role, and a dead button is worse than an absent one.

**A call is not a conversation.** It never enters the thread log — `notif.posted` is not
sent for a notification that classified as a call, or every ring would also leave a chat
row that can never be replied to. `state:"ended"` is sent when the phone withdraws the
notification, which is what ending a call does.

**Direction and state** come from `Notification.EXTRA_CALL_TYPE` when the notification is a
`CallStyle` one (`1` incoming → ringing, `2` ongoing → active, `3` screening → ringing).
Without it, an ongoing-flagged call notification is active and anything else is ringing.
Android never states the *direction*, so the phone infers it from how the call was first
seen — ringing means arriving — and the Mac uses it only to label a row in its recents.

**One call can arrive under two ids.** Some dialers do not update their notification when a
call is answered: they cancel it and post a fresh one. On the wire that is an `ended`
immediately followed by an unrelated `active`, which read literally is a missed call plus a
call from nowhere. The Mac folds a new call into the one that ended moments earlier when
the caller matches, so this stays one call — and one that was answered, not missed.

## App icons

Icons are content-addressed by hash so each one crosses the wire once, ever.

```jsonc
// Mac -> Android, "I don't have this icon cached"
{"v":1,"type":"icon.request","hash":"ab12cd…"}

// Android -> Mac, immediately followed by ONE binary frame with the PNG bytes
{"v":1,"type":"icon.data","hash":"ab12cd…","bytes":4096}
```

The Mac caches to `~/Library/Caches/com.tennanova.mac/icons/<hash>.png`.

## Clipboard

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
- **Neither side sends a peer content that peer is already known to hold**, and content it *sent
  us* counts exactly as much as content we sent it. Every `setPrimaryClip` makes Android raise its
  own "Copied" panel, so a clip that started on the phone and came back on the next `hello` push
  showed the user a second panel for one copy. Both ends therefore track one fingerprint of "what
  the peer has", updated on send *and* on receive, and the Mac notes the bytes that actually
  landed on its pasteboard rather than the ones that arrived — a phone JPEG is re-encoded to PNG
  on the way in, and the re-encoded bytes are what a later push would carry.
- A `clip.update` carrying `"origin":"android"` is our own copy coming home; Android drops it
  rather than applying it. An absent `origin` is still tolerated.
- Text remains compatible with peers that do not advertise image capability.
- **Mac → Android needs no Android permission** — `OP_WRITE_CLIPBOARD` is unconditional in AOSP.
- **Android → Mac requires Tennanova's one-time Accessibility grant.** The service detects an
  explicit copy signal, briefly owns a non-touchable Accessibility overlay to satisfy Android's
  focused-UID clipboard rule, reads one clip through public APIs, and removes the overlay.
  That overlay takes window focus but sets `FLAG_ALT_FOCUSABLE_IM` and
  `SOFT_INPUT_STATE_UNCHANGED`, so it never becomes the input method's target: without both, every
  clipboard read unbinds the IME from whatever the user was typing in and the keyboard drops, in
  every app on the phone.
- Copy detection must not treat typing as an interaction a copy could follow. A caret move
  (`fromIndex == toIndex`) and a tap into a text field both *disarm* the heuristic that reads a
  SystemUI window event as a copy chip; only a selected range or a tap on something that is not an
  editor arms it. Otherwise the overlay opens several times a second while the user types.
- Accessibility is not a direct clipboard exemption. Capture is disabled unless the session is
  authenticated, and **Share → Tennanova** is the fallback when an app exposes no copy signal.
- Clipboard does not sync while the phone is locked (`isDeviceLocked` short-circuits reads in
  `ClipboardService`). This is expected, not a bug.

## Versioning

Additive fields are fine within `v:1` — receivers must ignore unknown keys. Any change to the
meaning of an existing field, or any new message type that the peer must understand to behave
correctly, requires bumping `v`.
