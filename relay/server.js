import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer, createWebSocketStream } from 'ws';

/**
 * Tennanova relay — a blind byte pipe between one Mac and one phone.
 *
 * It exists for one reason: public and corporate Wi-Fi routinely enable AP client
 * isolation, which drops every packet between two clients of the same network. No
 * amount of LAN discovery can defeat that, because it is enforced in the access point.
 * Both devices *can* still reach the internet, so they each dial out to this server and
 * it forwards bytes between them.
 *
 * What it can and cannot see is the whole point of the design. The stream it forwards
 * is the phone's existing TLS session to the Mac — pinned to the Mac's public key, set
 * up end to end *through* this pipe. So the relay carries ciphertext it has no key for,
 * and a compromised relay can drop or delay a session but never read or forge one.
 * Nothing here parses, buffers to disk, or logs a single payload byte.
 */

const PORT = Number(process.env.PORT || 8080);

/** Room ids are hashes, so a host proves ownership by knowing the preimage. */
const roomIdFor = (secret) =>
  crypto.createHash('sha256').update(secret, 'utf8').digest('base64url');

/** How long a phone waits on the doorstep for the Mac to pick up its stream. */
const ACCEPT_TIMEOUT_MS = 15_000;
/** Silence after which a control channel is presumed dead and replaced. */
const HEARTBEAT_MS = 30_000;
/** One frame. Both ends chunk well below this; anything larger is not ours. */
const MAX_PAYLOAD = 1 << 20;

const MAX_ROOMS = Number(process.env.MAX_ROOMS || 5_000);
const MAX_PENDING_PER_ROOM = 4;

/** roomId -> { control, pending: Map<sid, Pending> } */
const rooms = new Map();

const log = (...args) => console.log(new Date().toISOString(), ...args);

function room(roomId, create = false) {
  let entry = rooms.get(roomId);
  if (!entry && create) {
    if (rooms.size >= MAX_ROOMS) return null;
    entry = { control: null, pending: new Map() };
    rooms.set(roomId, entry);
  }
  return entry || null;
}

function dropRoomIfIdle(roomId) {
  const entry = rooms.get(roomId);
  if (entry && !entry.control && entry.pending.size === 0) rooms.delete(roomId);
}

/**
 * Joins two sockets into one duplex pipe.
 *
 * `createWebSocketStream` rather than message forwarding: it gives real backpressure,
 * so a phone on slow cellular cannot make the relay buffer a 25 MB clipboard image in
 * memory on its behalf.
 */
function pipe(a, b, label) {
  const sa = createWebSocketStream(a);
  const sb = createWebSocketStream(b);
  let bytes = 0;
  const started = Date.now();

  const shutdown = () => {
    sa.destroy();
    sb.destroy();
    for (const socket of [a, b]) {
      if (socket.readyState === socket.OPEN) socket.close(1000, 'peer closed');
    }
  };

  sa.on('data', (chunk) => { bytes += chunk.length; });
  sa.on('error', shutdown);
  sb.on('error', shutdown);
  sa.on('close', shutdown);
  sb.on('close', shutdown);
  a.on('close', shutdown);
  b.on('close', shutdown);

  sa.pipe(sb);
  sb.pipe(sa);

  const done = () => {
    log(`stream closed ${label} bytes=${bytes} ms=${Date.now() - started}`);
  };
  a.once('close', done);
}

const server = http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, rooms: rooms.size }));
    return;
  }
  res.writeHead(404).end();
});

const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD, perMessageDeflate: false });

server.on('upgrade', (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, 'http://relay.invalid');
  } catch {
    socket.destroy();
    return;
  }

  const route = url.pathname;
  const handler = ROUTES[route];
  if (!handler) {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => handler(ws, url));
});

/** The Mac's long-lived control channel. Proves room ownership with the secret. */
function hostControl(ws, url) {
  const secret = (url.searchParams.get('secret') || '').trim();
  if (secret.length < 32 || secret.length > 512) {
    ws.close(4400, 'bad secret');
    return;
  }
  const roomId = roomIdFor(secret);
  const entry = room(roomId, true);
  if (!entry) {
    ws.close(4503, 'relay full');
    return;
  }

  // A Mac that restarted, or moved network, replaces its own earlier channel rather
  // than being refused by the ghost of it.
  if (entry.control && entry.control !== ws) {
    entry.control.close(4409, 'replaced by a newer host');
  }
  entry.control = ws;
  log(`host online room=${roomId.slice(0, 8)}`);

  ws.send(JSON.stringify({ t: 'ready', room: roomId }));

  let alive = true;
  ws.on('pong', () => { alive = true; });
  const beat = setInterval(() => {
    if (!alive) { ws.terminate(); return; }
    alive = false;
    if (ws.readyState === ws.OPEN) ws.ping();
  }, HEARTBEAT_MS);

  ws.on('close', () => {
    clearInterval(beat);
    if (entry.control === ws) {
      entry.control = null;
      log(`host offline room=${roomId.slice(0, 8)}`);
      // Nothing can pick these up any more; let the phones retry rather than hang.
      for (const pending of entry.pending.values()) pending.reject(4504, 'host went away');
      entry.pending.clear();
      dropRoomIfIdle(roomId);
    }
  });
}

/** The Mac claiming one waiting phone stream. */
function hostAccept(ws, url) {
  const secret = (url.searchParams.get('secret') || '').trim();
  const sid = (url.searchParams.get('sid') || '').trim();
  const roomId = roomIdFor(secret);
  const entry = rooms.get(roomId);
  const pending = entry?.pending.get(sid);
  if (!pending) {
    ws.close(4404, 'no such stream');
    return;
  }
  entry.pending.delete(sid);
  pending.settle(ws);
  log(`stream open room=${roomId.slice(0, 8)} sid=${sid.slice(0, 8)}`);
  pipe(pending.ws, ws, `room=${roomId.slice(0, 8)} sid=${sid.slice(0, 8)}`);
}

/** The phone asking to be connected to whichever Mac owns this room. */
function guestJoin(ws, url) {
  const roomId = (url.searchParams.get('room') || '').trim();
  if (!roomId || roomId.length > 128) {
    ws.close(4400, 'bad room');
    return;
  }
  const entry = rooms.get(roomId);
  if (!entry || !entry.control || entry.control.readyState !== entry.control.OPEN) {
    // Deliberately the same answer as an unknown room: a stranger probing ids learns
    // nothing about which Macs exist.
    ws.close(4404, 'mac not reachable');
    return;
  }
  if (entry.pending.size >= MAX_PENDING_PER_ROOM) {
    ws.close(4429, 'too many pending streams');
    return;
  }

  const sid = crypto.randomBytes(16).toString('base64url');
  let done = false;

  const timer = setTimeout(() => {
    if (done) return;
    done = true;
    entry.pending.delete(sid);
    if (ws.readyState === ws.OPEN) ws.close(4408, 'mac did not answer');
    dropRoomIfIdle(roomId);
  }, ACCEPT_TIMEOUT_MS);

  entry.pending.set(sid, {
    ws,
    settle: () => { done = true; clearTimeout(timer); },
    reject: (code, reason) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (ws.readyState === ws.OPEN) ws.close(code, reason);
    }
  });

  ws.on('close', () => {
    clearTimeout(timer);
    entry.pending.delete(sid);
    dropRoomIfIdle(roomId);
  });

  entry.control.send(JSON.stringify({ t: 'open', sid }));
}

const ROUTES = {
  '/v1/host': hostControl,
  '/v1/accept': hostAccept,
  '/v1/join': guestJoin
};

server.listen(PORT, () => log(`tennanova relay listening on ${PORT}`));

export { roomIdFor, rooms, server };
