// Stands in for the phone's RelayBridge so a relay can be verified without one.
//
// It joins a Mac's room and exposes the far end as a local TCP port, which turns the
// whole path into something `openssl` can check:
//
//   node tools/fake-phone.mjs wss://your-relay.fly.dev <room-id> 9446
//   echo | openssl s_client -connect 127.0.0.1:9446 -brief
//
// A handshake reporting `CN=TennaNova Mac` proves the entire chain: control channel,
// stream hand-off, both byte pumps, and the Mac's listener at the end of it. That is
// the exact path the phone takes, and the certificate it pins.

import net from 'node:net';
import WebSocket from 'ws';

const [, , relay, room, listenPort] = process.argv;
if (!relay || !room || !listenPort) {
  console.error('usage: node tools/fake-phone.mjs <wss://relay> <room-id> <local-port>');
  process.exit(2);
}

net.createServer((local) => {
  const ws = new WebSocket(`${relay}/v1/join?room=${encodeURIComponent(room)}`);
  ws.on('open', () => {
    console.error('[phone] joined room, piping');
    local.on('data', (chunk) => ws.send(chunk));
  });
  ws.on('message', (chunk) => local.write(chunk));
  ws.on('close', (code, reason) => {
    console.error('[phone] relay closed', code, reason.toString());
    local.end();
  });
  ws.on('error', (e) => { console.error('[phone] relay error', e.message); local.destroy(); });
  local.on('close', () => ws.close());
  local.on('error', () => ws.close());
}).listen(Number(listenPort), '127.0.0.1', () => {
  console.error(`[phone] listening on 127.0.0.1:${listenPort}`);
});
