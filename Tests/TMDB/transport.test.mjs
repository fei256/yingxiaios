import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import { fetchTMDB } from '../../Runtime/NodeHost/tmdb-transport.mjs';

async function listen(t, server) {
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); });
  return server.address().port;
}
async function origin(t, responder) {
  const requests = [];
  const server = createServer((request, response) => {
    requests.push({ url: request.url, headers: request.headers });
    if (responder) responder(request, response, requests.length);
    else {
      response.writeHead(200, { 'Content-Type': request.url.includes('image') ? 'image/png' : 'application/json' });
      response.end(request.url.includes('image') ? Buffer.from([137, 80, 78, 71]) : JSON.stringify({ images: {}, ok: true }));
    }
  });
  const port = await listen(t, server);
  return { port, url: `http://127.0.0.1:${port}`, requests };
}
async function httpProxy(t, port, credentials) {
  const connects = [], upstreams = new Set();
  const server = createServer();
  server.on('connect', (request, client, head) => {
    connects.push({ target: request.url, authorization: request.headers['proxy-authorization'] });
    const expected = credentials && 'Basic ' + Buffer.from(credentials).toString('base64');
    if (expected && request.headers['proxy-authorization'] !== expected) { client.end('HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n'); return; }
    const upstream = net.connect(port, '127.0.0.1'); upstreams.add(upstream);
    upstream.on('close', () => upstreams.delete(upstream)); upstream.on('error', () => client.destroy());
    client.on('error', () => upstream.destroy()); client.on('close', () => upstream.destroy());
    upstream.once('connect', () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      client.pipe(upstream); upstream.pipe(client);
    });
  });
  const proxyPort = await listen(t, server);
  t.after(() => { for (const socket of upstreams) socket.destroy(); });
  return { url: `http://127.0.0.1:${proxyPort}`, connects };
}
async function socksProxy(t, port, credentials) {
  const targets = [], authenticated = [], upstreams = new Set();
  const server = net.createServer(socket => {
    let buffer = Buffer.alloc(0), state = 'greeting';
    const parse = () => {
      while (true) {
        if (state === 'greeting') {
          if (buffer.length < 2 || buffer.length < 2 + buffer[1]) return;
          buffer = buffer.subarray(2 + buffer[1]); socket.write(Buffer.from([5, credentials ? 2 : 0]));
          state = credentials ? 'authentication' : 'request';
        } else if (state === 'authentication') {
          if (buffer.length < 2 || buffer.length < 3 + buffer[1]) return;
          const userLength = buffer[1], passLength = buffer[2 + userLength];
          if (buffer.length < 3 + userLength + passLength) return;
          const supplied = buffer.subarray(2, 2 + userLength).toString() + ':' + buffer.subarray(3 + userLength, 3 + userLength + passLength).toString();
          authenticated.push(supplied === credentials); buffer = buffer.subarray(3 + userLength + passLength);
          socket.write(Buffer.from([1, supplied === credentials ? 0 : 1]));
          if (supplied !== credentials) { socket.end(); return; }
          state = 'request';
        } else if (state === 'request') {
          if (buffer.length < 5 || buffer.length < 7 + buffer[4]) return;
          const length = buffer[4]; targets.push(buffer.subarray(5, 5 + length).toString());
          buffer = buffer.subarray(7 + length); state = 'connecting';
          const upstream = net.connect(port, '127.0.0.1'); upstreams.add(upstream);
          upstream.on('close', () => upstreams.delete(upstream)); upstream.on('error', () => socket.destroy());
          socket.on('close', () => upstream.destroy()); socket.on('error', () => upstream.destroy());
          upstream.once('connect', () => {
            socket.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, 0, 0])); socket.off('data', received);
            if (buffer.length) upstream.write(buffer);
            socket.pipe(upstream); upstream.pipe(socket);
          });
          return;
        } else return;
      }
    };
    const received = bytes => { buffer = Buffer.concat([buffer, bytes]); parse(); };
    socket.on('data', received); socket.on('error', () => {});
  });
  const proxyPort = await listen(t, server);
  t.after(() => { for (const socket of upstreams) socket.destroy(); });
  return { url: `socks5://127.0.0.1:${proxyPort}`, targets, authenticated };
}

test('direct TMDB API requests preserve authentication and returned data', { timeout: 5000 }, async t => {
  const service = await origin(t);
  const result = await fetchTMDB({ url: service.url + '/3/configuration?api_key=fixture-key', headers: { Authorization: 'Bearer fixture-token' } });
  assert.equal(JSON.parse(Buffer.from(result.data, 'base64')).ok, true);
  assert.equal(service.requests[0].headers.authorization, 'Bearer fixture-token');
  assert.ok(service.requests[0].url.includes('api_key=fixture-key'));
});

test('API and image requests use the same authenticated HTTP proxy', { timeout: 5000 }, async t => {
  const service = await origin(t), proxy = await httpProxy(t, service.port, 'fixture-user:fixture-password');
  const params = { proxy: { url: proxy.url, username: 'fixture-user', password: 'fixture-password' }, headers: { Authorization: 'Bearer fixture-token' } };
  const root = `http://tmdb.fixture:${service.port}`;
  const api = await fetchTMDB({ ...params, url: root + '/3/configuration' });
  const image = await fetchTMDB({ ...params, url: root + '/t/p/w185/image.png' });
  assert.equal(JSON.parse(Buffer.from(api.data, 'base64')).ok, true);
  assert.deepEqual(Buffer.from(image.data, 'base64'), Buffer.from([137, 80, 78, 71]));
  assert.equal(proxy.connects.length, 2);
  assert.ok(proxy.connects.every(value => value.target === `tmdb.fixture:${service.port}`));
  assert.ok(service.requests.every(value => value.headers['proxy-authorization'] === undefined));
});

test('SOCKS5 sends DNS names through the proxy and uses fresh authentication', { timeout: 5000 }, async t => {
  const service = await origin(t), proxy = await socksProxy(t, service.port, 'fixture-user:fixture-password');
  const value = await fetchTMDB({ url: `http://tmdb.fixture:${service.port}/3/configuration`,
    proxy: { url: proxy.url, username: 'fixture-user', password: 'fixture-password' } });
  assert.equal(JSON.parse(Buffer.from(value.data, 'base64')).ok, true);
  assert.deepEqual(proxy.targets, ['tmdb.fixture']); assert.deepEqual(proxy.authenticated, [true]);
  await assert.rejects(() => fetchTMDB({ url: `http://tmdb.fixture:${service.port}/3/configuration`,
    proxy: { url: proxy.url, username: 'fixture-user', password: 'incorrect' } }), /代理认证失败/);
  assert.equal(service.requests.length, 1);
});

test('incorrect HTTP proxy credentials fail without reaching the origin', { timeout: 5000 }, async t => {
  const service = await origin(t), proxy = await httpProxy(t, service.port, 'fixture-user:fixture-password');
  await assert.rejects(() => fetchTMDB({ url: service.url + '/3/configuration',
    proxy: { url: proxy.url, username: 'fixture-user', password: 'incorrect' } }), /代理认证失败/);
  assert.equal(service.requests.length, 0);
});

test('TMDB authentication errors do not consume a retry budget', { timeout: 5000 }, async t => {
  const service = await origin(t, (_, response) => response.writeHead(401).end());
  await assert.rejects(() => fetchTMDB({ url: service.url + '/3/configuration' }), error => error.httpStatus === 401);
  assert.equal(service.requests.length, 1);
});

test('transient TMDB status retries once and then returns a terminal failure', { timeout: 5000 }, async t => {
  const service = await origin(t, (_, response, count) => {
    if (count === 1) response.writeHead(429).end();
    else response.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
  });
  assert.equal(JSON.parse(Buffer.from((await fetchTMDB({ url: service.url + '/3/configuration' })).data, 'base64')).ok, true);
  assert.equal(service.requests.length, 2);
  const failing = await origin(t, (_, response) => response.writeHead(503).end());
  await assert.rejects(() => fetchTMDB({ url: failing.url + '/3/configuration' }), error => error.httpStatus === 503);
  assert.equal(failing.requests.length, 2);
});

test('cancelled image acquisition closes its active body instead of retrying', { timeout: 5000 }, async t => {
  const service = await origin(t, (_, response) => { response.writeHead(200); response.write('partial'); });
  const controller = new AbortController();
  const request = fetchTMDB({ url: service.url + '/image.png' }, controller.signal);
  await delay(40); controller.abort(new Error('fixture cancellation'));
  await assert.rejects(() => request, /fixture cancellation/);
  assert.equal(service.requests.length, 1);
});

test('oversized images and malformed target or proxy URLs are rejected', { timeout: 5000 }, async t => {
  const service = await origin(t, (_, response) => response.writeHead(200, { 'Content-Length': String(25 * 1024 ** 2) }).end('too large'));
  await assert.rejects(() => fetchTMDB({ url: service.url + '/image.png' }), /超过大小限制/);
  for (const url of ['file:///tmp/image.png', 'http://name:password@host/image', service.url + '/image#fragment'])
    await assert.rejects(() => fetchTMDB({ url }), /TMDB 地址无效/);
  await assert.rejects(() => fetchTMDB({ url: service.url, proxy: { url: 'ftp://127.0.0.1:8080' } }), /代理地址/);
});
