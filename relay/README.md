# Tennanova relay

A blind byte pipe between one Mac and one phone, for networks that refuse to carry
traffic between their own clients.

## Why this exists

Public, hotel and corporate Wi-Fi very often run **AP client isolation**: every packet
from one client to another is dropped at the access point. Tennanova's LAN transport
cannot work there, and no amount of mDNS or subnet probing changes it — the block is
below the layer an app runs at. The signature is unmistakable once you look for it: on
one such network the Mac could see 45 neighbours in its ARP table, zero other Bonjour
services, and not one open TCP port among them.

Both devices can still reach the internet. So each dials *out* to this server, and it
forwards bytes between them.

## What it can see: nothing

The stream this server forwards is the phone's ordinary TLS session to the Mac, pinned
to the Mac's public key and negotiated end to end *through* the pipe. The relay carries
ciphertext it holds no key for. A hostile or compromised relay can delay or drop a
session; it cannot read one, forge one, or authenticate as either device — the pairing
token check still happens inside the tunnel, on the Mac.

Nothing here parses, stores, or logs a payload byte. Logs record room prefixes, byte
counts and durations only.

## Rooms

A room is named by `base64url(sha256(secret))`.

- The **Mac** holds the secret and is the only party that can host the room.
- The **phone** is given only the room id, in the pairing QR, and can join with it.

Knowing a room id lets someone open a TCP pipe to the Mac's listener — exactly the
exposure of being on the same LAN as the Mac, and no more. The pinned certificate and
the pairing token are what actually guard the session.

## Endpoints

| Path | Who | Purpose |
| --- | --- | --- |
| `/v1/host?secret=…` | Mac | Long-lived control channel. Replies `{"t":"ready","room":…}`, then pushes `{"t":"open","sid":…}` per waiting phone. |
| `/v1/accept?secret=…&sid=…` | Mac | Data channel claiming one waiting stream. |
| `/v1/join?room=…` | Phone | Data channel. Waits up to 15s for the Mac to accept. |
| `/health` | anyone | `{"ok":true,"rooms":n}` |

## Running it

```bash
npm install && npm start
```

```bash
npm test
```

## Verifying a deployment

`tools/fake-phone.mjs` stands in for the phone, so the relay can be proven end to end
before an APK is anywhere near it:

```bash
node tools/fake-phone.mjs wss://your-relay.fly.dev <room-id> 9446
echo | openssl s_client -connect 127.0.0.1:9446 -brief
```

A handshake reporting `CN=TennaNova Mac` means the whole chain works — control channel,
stream hand-off, both byte pumps, and the Mac's own listener at the far end.

The room id is what the Mac puts in its QR. It can also be derived from the Mac's stored
secret: `base64url(sha256(secret))`, where the secret is `defaults read com.tennanova.mac
relaySecret`.

## Deploying

It needs a host that keeps a plain WebSocket open indefinitely and terminates TLS.
Fly.io is configured here; Railway, Render or a VPS behind Caddy work the same way.

```bash
fly launch --copy-config --no-deploy && fly deploy
```

**Serverless will not work.** Vercel/Lambda-style functions cap request duration, and a
Tennanova session is meant to idle for hours. Hosting a static site on one of those says
nothing about whether it can carry this.

Once deployed, put the host name in `TennaNova/Core/Relay.swift` (`Relay.defaultHost`)
and `com/tennanova/net/RelayConfig.kt` so new pairings carry it in the QR.
