import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { once } from 'node:events';
import WebSocket from 'ws';

process.env.PORT = '0';
const { server, roomIdFor } = await import('../server.js');
if (!server.listening) await once(server, 'listening');
const base = `ws://127.0.0.1:${server.address().port}`;

const SECRET = crypto.randomBytes(32).toString('base64');
const ROOM = roomIdFor(SECRET);

/**
 * Listeners are attached before `open` is awaited, never after.
 *
 * The relay greets a control channel the instant the handshake completes, and ws can
 * emit that first message in the same turn as `open` — a listener registered after
 * awaiting `open` misses it and waits forever.
 */
const opened = new Set();

function connect(path) {
  const ws = new WebSocket(`${base}${path}`);
  opened.add(ws);
  ws.on('close', () => opened.delete(ws));
  const messages = [];
  const waiters = [];
  ws.on('message', (raw) => {
    const next = waiters.shift();
    if (next) next(raw);
    else messages.push(raw);
  });
  ws.next = () =>
    messages.length ? Promise.resolve(messages.shift())
                    : new Promise((resolve) => waiters.push(resolve));
  ws.opened = once(ws, 'open').then(() => ws);
  return ws;
}

const open = (path) => connect(path).opened;

/**
 * Drives the Mac end.
 *
 * `accept: false` is a Mac that is online but never picks the stream up — the only way
 * to observe what a phone left on the doorstep is actually told.
 */
async function hostOnline(secret, { accept = true } = {}) {
  const control = connect(`/v1/host?secret=${encodeURIComponent(secret)}`);
  await control.opened;
  assert.equal(JSON.parse(await control.next()).t, 'ready');
  if (!accept) return { control, accepted: null };
  const accepted = control.next().then((raw) => {
    const msg = JSON.parse(raw);
    assert.equal(msg.t, 'open');
    return open(
      `/v1/accept?secret=${encodeURIComponent(secret)}&sid=${encodeURIComponent(msg.sid)}`
    );
  });
  return { control, accepted };
}

test('a room id is the hash of the secret, so only the Mac can host it', () => {
  assert.equal(roomIdFor(SECRET), roomIdFor(SECRET));
  assert.notEqual(roomIdFor(SECRET), roomIdFor(crypto.randomBytes(32).toString('base64')));
  // The phone is given this and it leaks nothing usable back.
  assert.doesNotMatch(ROOM, /[+/=]/, 'room ids must be URL-safe');
});

test('bytes cross in both directions once the Mac accepts', async () => {
  const { control, accepted } = await hostOnline(SECRET);
  const guest = await open(`/v1/join?room=${encodeURIComponent(ROOM)}`);
  const mac = await accepted;

  guest.send(Buffer.from('hello mac'));
  assert.equal((await mac.next()).toString(), 'hello mac');

  mac.send(Buffer.from('hello phone'));
  assert.equal((await guest.next()).toString(), 'hello phone');

  guest.close();
  control.close();
});

test('a large payload survives the pipe intact', async () => {
  const { control, accepted } = await hostOnline(SECRET);
  const guest = await open(`/v1/join?room=${encodeURIComponent(ROOM)}`);
  const mac = await accepted;

  // Chunked the way both clients chunk a clipboard image, and compared as one blob:
  // the pipe carries a byte stream, so frame boundaries are explicitly not preserved.
  const payload = crypto.randomBytes(512 * 1024);
  const received = new Promise((resolve) => {
    const parts = [];
    let total = 0;
    mac.on('message', (chunk) => {
      parts.push(chunk);
      total += chunk.length;
      if (total >= payload.length) resolve(Buffer.concat(parts));
    });
  });
  for (let at = 0; at < payload.length; at += 64 * 1024) {
    guest.send(payload.subarray(at, at + 64 * 1024));
  }
  assert.equal(Buffer.compare(await received, payload), 0);

  guest.close();
  control.close();
});

test('a base64 secret survives the query string intact', async () => {
  // Both clients percent-encode query values themselves precisely because of this:
  // `URLSearchParams` reads a bare `+` as a space, and every secret is base64, so a
  // client that let `+` through would make the relay hash a different string and host
  // a room under a name its own Mac never computed.
  // A real secret: 32 random bytes in base64, rerolled until it carries the two
  // characters that actually cause trouble. Short literals are rejected outright.
  let awkward = '';
  while (!awkward.includes('+') || !awkward.includes('/')) {
    awkward = crypto.randomBytes(32).toString('base64');
  }
  const { control, accepted } = await hostOnline(awkward);
  const guest = await open(`/v1/join?room=${encodeURIComponent(roomIdFor(awkward))}`);
  const mac = await accepted;
  guest.send(Buffer.from('plus signs are fine'));
  assert.equal((await mac.next()).toString(), 'plus signs are fine');
  guest.close();
  control.close();
});

test('a phone is refused when its Mac has never been online', async () => {
  const stranger = connect(`/v1/join?room=${roomIdFor('nobody-is-hosting-this')}`);
  const [code] = await once(stranger, 'close');
  assert.equal(code, 4404);
});

test('knowing the room id does not let anyone host it', async () => {
  // The room id is public — it travels in the QR. The secret behind it does not, and
  // hashing the id a second time cannot name any room that exists.
  const impostor = connect(`/v1/accept?secret=${encodeURIComponent(ROOM)}&sid=whatever`);
  const [code] = await once(impostor, 'close');
  assert.equal(code, 4404);
});

test('a Mac that restarts replaces its own stale control channel', async () => {
  const first = await hostOnline(SECRET);
  const closed = once(first.control, 'close');
  const second = await hostOnline(SECRET);
  assert.equal((await closed)[0], 4409);

  // And the room still works through the new channel.
  const guest = await open(`/v1/join?room=${encodeURIComponent(ROOM)}`);
  const mac = await second.accepted;
  guest.send(Buffer.from('still here'));
  assert.equal((await mac.next()).toString(), 'still here');

  guest.close();
  second.control.close();
});

test('a phone waiting on a Mac that vanishes is told, not left hanging', async () => {
  const { control } = await hostOnline(SECRET, { accept: false });
  const guest = await open(`/v1/join?room=${encodeURIComponent(ROOM)}`);
  const closed = once(guest, 'close');
  control.close();
  assert.equal((await closed)[0], 4504);
});

test.after(() => {
  // Sockets the relay has no reason to close on its own would otherwise hold the test
  // process open long after the last assertion.
  for (const ws of opened) ws.terminate();
  server.closeAllConnections?.();
  server.close();
});
