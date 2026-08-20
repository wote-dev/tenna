# Security

## Reporting a vulnerability

Please report privately through **GitHub Security Advisories** — the *Report a vulnerability*
button under this repository's Security tab. That opens a channel visible only to you and the
maintainer. Do not open a public issue for a vulnerability.

A useful report says what an attacker gains, and where they have to be standing to get it: on
the same LAN, on the relay, in possession of the Mac's disk, or holding a paired phone. If you
have a proof of concept, include it; if you only have a plausible attack, send it anyway.

This is a personal project, not a funded one. There is no bounty, and there is no SLA — but
reports get read and acted on.

## What Tennanova is trying to protect

- **Everything on the wire.** Phone and Mac talk over one TLS session pinned to the Mac's
  self-signed key. The phone's `X509TrustManager` trusts that key and nothing else; a pin
  mismatch is fatal and surfaced, never retried.
- **Everything through the relay.** The relay forwards the *same* pinned TLS session,
  negotiated end to end through it. It carries ciphertext it holds no key for, and nothing in
  it parses, stores or logs a payload byte.
- **Pairing.** The QR carries a one-time token. It is exchanged for a long-lived device token
  and then discarded. Only the holder of the room secret — the Mac — can host a relay room; the
  phone is handed the room id, which lets it join and never host.
- **Your data staying yours.** No account, no cloud service, no telemetry, no analytics SDK, no
  crash reporter. The only network destinations are your own Mac and, if you leave it enabled,
  a relay that cannot read what it carries.

## What it does not protect against

Being explicit about this is more useful than implying more than is true.

- **A compromised Mac or phone.** Mirrored conversations are stored unencrypted at rest in
  `~/Library/Application Support/com.tennanova.mac/history.json`, protected by file permissions
  and whatever FileVault gives you. Anything running as your user can read them.
- **The TLS private key, against local code running as you.** It lives in a 0600 PKCS#12 under
  Application Support, with its password in a 0600 file beside it, and is imported into an
  app-owned keychain whose ACL deliberately trusts all applications. That last part is a
  considered trade: the login Keychain's per-application ACL is unusable for an ad-hoc-signed
  app, because every rebuild invalidates it and the resulting password prompt blocks startup.
  The threat this drops — another process *on your own Mac, running as you* borrowing the key —
  is one that a process able to read the 0600 password file already has.
- **Traffic analysis at the relay.** The relay learns that a room is in use, roughly when, and
  how much data moves. It cannot learn what.
- **Anything Android exposes to a notification listener.** The phone app reads notifications
  through `NotificationListenerService` and the SMS provider through the platform's own
  permissions. It cannot do more than those grants allow, and it does not try to.

## Scope

In scope: both apps, the relay, and `protocol/PROTOCOL.md`.

Out of scope: findings that require a Mac or phone that is already compromised, and reports that
amount to
"deprecated `SecKeychain` API is used", which is a documented and deliberate choice —
`mac/Sources/TennaNova/Server/TLSIdentity.swift` explains why, and the modern replacement is
gated behind a paid Apple Developer account this project deliberately does not require.
