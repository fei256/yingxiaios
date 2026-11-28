import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import { MediaCache } from '../../Runtime/NodeHost/parity/lib/media-cache.mjs';
import { MobileServices } from '../../Runtime/NodeHost/mobile-services.mjs';

const blockBytes = 1024;

async function fixture(t, { length = 10 * blockBytes, request: responder } = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'yingxia-playback-cache-'));
  const requests = [];
  const media = Buffer.from(Array.from({ length }, (_, index) => index % 251));
  const request = async (address, options) => {
    const headers = new Headers(options.headers);
    const range = /^bytes=(\d+)-(\d*)$/.exec(headers.get('range') || '');
    const start = range ? Number(range[1]) : 0;
    const end = range?.[2] ? Math.min(Number(range[2]), media.length - 1) : media.length - 1;
    const call = { start, end, ifRange: headers.get('if-range'), signal: options.signal, method: options.method };
    requests.push(call);
    const value = await responder?.(call, requests.length, media) || {};
    const responseEnd = Math.min(end, value.rangeEnd ?? end);
    const body = Readable.from((async function* () {
      for (let offset = start; offset <= responseEnd; offset += blockBytes) {
        options.signal.throwIfAborted();
        if (value.cutAt !== undefined && offset >= value.cutAt) {
          if (value.error) throw new Error('connection reset');
          return;
        }
        yield media.subarray(offset, Math.min(offset + blockBytes, responseEnd + 1));
        await delay(value.delayMs ?? 1, undefined, { signal: options.signal });
      }
    })());
    const responseHeaders = { 'content-length': String(responseEnd - start + 1),
      'content-type': 'video/mp4', 'accept-ranges': 'bytes' };
    if (range) responseHeaders['content-range'] = `bytes ${start}-${responseEnd}/${media.length}`;
    if (value.validator !== false) responseHeaders.etag = value.validator || '"video-v1"';
    return { response: new Response(Readable.toWeb(body), { status: range ? 206 : 200, headers: responseHeaders }),
      url: address, release() {} };
  };
  const cache = new MediaCache({ dataDirectory: directory, baseUrl: 'http://127.0.0.1',
    blockBytes, reserveBytes: 0, idleTimeoutMs: 1000, request });
  t.after(async () => {
    await cache.close();
    assert.equal(path.dirname(directory), path.resolve(os.tmpdir()));
    assert.ok(path.basename(directory).startsWith('yingxia-playback-cache-'));
    await fs.rm(directory, { recursive: true, force: true });
  });
  await cache.ready;
  const owner = cache.createSession('playing', { enabled: true, sizeGB: 2 });
  const resource = cache.resource(owner, 'https://media.example/video.mp4');
  resource.forwardCache = true;
  const signal = owner.controller.signal;
  async function open(range = 'bytes=0-') {
    const upstream = await cache.open(resource, 'GET', range, '', signal);
    const meta = cache.accept(resource, upstream.response);
    const iterator = cache.playbackBody(resource, upstream, meta, signal)[Symbol.asyncIterator]();
    t.after(async () => { await iterator.return?.().catch(() => {}); });
    return iterator;
  }
  return { cache, owner, resource, media, requests, open };
}

async function waitFor(check, message) {
  const deadline = Date.now() + 1500;
  while (!check() && Date.now() < deadline) await delay(5);
  assert.ok(check(), message);
}

async function consume(iterator, first) {
  const chunks = first?.value ? [first.value] : [];
  for await (const bytes of { [Symbol.asyncIterator]: () => iterator }) chunks.push(bytes);
  return Buffer.concat(chunks);
}

test('next episode yields both before and during a current episode read', { timeout: 5000 }, async t => {
  const { cache, resource, owner, requests } = await fixture(t, { request: () => ({ delayMs: 15 }) });
  const service = Object.assign(Object.create(MobileServices.prototype), { cache });
  const next = cache.createSession('next', { enabled: true, sizeGB: 2 });
  cache.resource(next, 'https://media.example/next.mp4');
  const warm = () => service.call('playback.prefetch', { id: next.id }, next.controller.signal);
  const foreground = () => cache.open(resource, 'GET', 'bytes=0-1023', '', owner.controller.signal);
  async function release(read) {
    read.controller.abort(); await read.response.body.cancel(); read.releaseBudget();
  }

  const first = await foreground();
  assert.equal((await warm()).deferred, true);
  assert.equal(requests.length, 1);
  await release(first);
  const interrupted = assert.rejects(warm());
  await waitFor(() => requests.length === 2, 'next episode should acquire the idle transport');
  const second = await foreground();
  await interrupted;
  assert.equal(requests[1].signal.aborted, true);
  await release(second);
  assert.ok((await warm()).bytes > 0);
});

test('episode warm resumes a capped prefix only with an entity validator', async t => {
  for (const validator of [false, '"stable"']) {
    const { cache, owner, requests } = await fixture(t, {
      request: ({ start }) => ({ rangeEnd: start + blockBytes - 1, validator })
    });
    const service = Object.assign(Object.create(MobileServices.prototype), { cache });
    const warm = () => service.call('playback.prefetch', { id: owner.id, maxBytes: blockBytes * 2 }, owner.controller.signal);
    const first = await warm();
    assert.equal(first.deferred === true, !!validator);
    await warm();
    assert.deepEqual(requests.map(r => [r.start, r.ifRange]), validator ? [[0, null], [blockBytes, validator]] : [[0, null]]);
  }
});

test('dense danmaku shortens lookahead, signals an overfull interval and recovers', async t => {
  const { cache } = await fixture(t);
  const service = Object.assign(Object.create(MobileServices.prototype), {
    directory: cache.directory, danmakuRevision: 0, session: { id: 'episode' }
  });
  const comments = Array.from({ length: 10001 }, (_, i) => ({ time: 60 + i / 10000, text: String(i), mode: 1 }));
  comments.unshift({ time: 1, text: 'start', mode: 1 });
  comments.push({ time: 150, text: 'end', mode: 1 });
  await service.call('danmaku.prepare', { sessionId: 'episode', text: JSON.stringify(comments) });
  const windowAt = position => service.call('danmaku.window', { sessionId: 'episode', position, duration: 90 });
  assert.deepEqual((await windowAt(0)).items.map(item => item.text), ['start']);
  assert.equal((await windowAt(60)).tooDense, true);
  assert.deepEqual((await windowAt(150)).items.map(item => item.text), ['end']);
});

test('finite file ranges fill disk ahead of a paused decoder', { timeout: 5000 }, async t => {
  const { owner, media, open } = await fixture(t);
  const iterator = await open(`bytes=0-${media.length - 1}`);
  const first = await iterator.next();
  await waitFor(() => owner.bytes === media.length, 'the disk cache must finish without more decoder reads');
  assert.equal(owner.maxBytes, 2 * 1024 ** 3);
  assert.deepEqual(await consume(iterator, first), media);
});

test('a bounded subrange preserves its exact response boundaries', { timeout: 5000 }, async t => {
  const { cache, resource, media, requests, open } = await fixture(t);
  const iterator = await open(`bytes=${blockBytes}-${4 * blockBytes - 1}`);
  const first = await iterator.next();
  await waitFor(() => cache.covers(resource, blockBytes, 4 * blockBytes - 1), 'the requested subrange must be fully pre-read');
  assert.deepEqual(await consume(iterator, first), media.subarray(blockBytes, 4 * blockBytes));
  assert.equal(requests[0].end, 4 * blockBytes - 1);
});

test('a capped open Range fills the entire file while its decoder stops consuming the short response', { timeout: 5000 }, async t => {
  const { cache, owner, media, requests, open } = await fixture(t, {
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1 }),
  });
  const iterator = await open();
  const first = await iterator.next();
  await waitFor(() => cache.statistics(owner.id).complete, 'a short first 206 must not end whole-file pre-reading');
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, media.length);
  assert.equal(cache.statistics(owner.id).mediaBytes, media.length);
  assert.ok(requests.length > 1);
  assert.ok(requests.slice(1).every(call => call.ifRange === '"video-v1"'));
  assert.deepEqual(await consume(iterator, first), media.subarray(0, 2 * blockBytes));
});

test('whole-file prefetch outlives a normally completed finite HTTP response without changing its headers', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media, requests } = await fixture(t, {
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1 }),
  });
  const server = createServer((request, response) => {
    void cache.transfer(owner, resource, {}, request, response).catch(() => response.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeIdleConnections();
    await new Promise(resolve => server.close(resolve));
  });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/video`, {
    headers: { Range: `bytes=0-${2 * blockBytes - 1}` },
  });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('content-length'), String(2 * blockBytes));
  assert.equal(response.headers.get('content-range'), `bytes 0-${2 * blockBytes - 1}/${media.length}`);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), media.subarray(0, 2 * blockBytes));
  await waitFor(() => cache.statistics(owner.id).complete, 'prefetch must continue after the HTTP response ends');
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, media.length);
  assert.ok(requests.slice(1).every(call => call.end - call.start + 1 <= 8 * blockBytes));
});

test('a validated cached prefix streams capped upstream ranges into the requested HTTP response', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media, requests } = await fixture(t, {
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1 }),
  });
  resource.forwardCache = false;
  cache.accept(resource, new Response(null, { status: 206, headers: {
    'content-range': `bytes 0-${media.length - 1}/${media.length}`,
    'content-length': String(media.length), etag: '"video-v1"',
  } }));
  for (let start = 0; start < 2 * blockBytes; start += blockBytes)
    await cache.put(resource, start, media.subarray(start, start + blockBytes));
  const server = createServer((request, response) => {
    void cache.transfer(owner, resource, {}, request, response).catch(() => response.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeIdleConnections();
    await new Promise(resolve => server.close(resolve));
  });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/video`, { headers: { Range: 'bytes=0-' } });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('content-length'), String(media.length));
  assert.equal(response.headers.get('content-range'), `bytes 0-${media.length - 1}/${media.length}`);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), media);
  assert.equal(requests[0].start, 2 * blockBytes);
  assert.ok(requests.every(call => call.ifRange === '"video-v1"'));
});

test('a completed foreground HEAD resumes the whole-file prefetch it briefly interrupted', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media, requests, open } = await fixture(t, {
    request: call => call.method === 'HEAD' ? {} : { rangeEnd: call.start + 2 * blockBytes - 1, delayMs: 5 },
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => requests.length >= 2 && cache.filePrefetchActive, 'background prefetch should start');
  const server = createServer((request, response) => {
    void cache.transfer(owner, resource, {}, request, response).catch(() => response.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeIdleConnections();
    await new Promise(resolve => server.close(resolve));
  });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/video`, { method: 'HEAD' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-length'), String(media.length));
  await waitFor(() => cache.statistics(owner.id).complete, 'the successful metadata request must not permanently stop prefetch');
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, media.length);
});

test('capped responses without a validator keep their original acquisition boundary', { timeout: 5000 }, async t => {
  const { cache, owner, media, requests, open } = await fixture(t, {
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1, validator: false }),
  });
  const iterator = await open();
  assert.deepEqual(await consume(iterator), media.subarray(0, 2 * blockBytes));
  await delay(20);
  assert.equal(requests.length, 1);
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, 2 * blockBytes);
  assert.equal(cache.statistics(owner.id).complete, false);
});

test('whole-file prefetch recovers a truncated background range from its stored prefix', { timeout: 5000 }, async t => {
  const { cache, owner, media, requests, open } = await fixture(t, {
    request: (call, number) => ({ rangeEnd: call.start + 2 * blockBytes - 1,
      ...(number === 2 ? { cutAt: call.start + blockBytes } : {}) }),
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => cache.statistics(owner.id).complete, 'the stored background prefix should survive a truncation');
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, media.length);
  assert.equal(requests[2].start, 3 * blockBytes);
  assert.ok(requests[1].signal.aborted);
});

test('background prefetch rejects a changed entity instead of silently caching it', { timeout: 5000 }, async t => {
  const { cache, owner, requests, open } = await fixture(t, {
    request: (call, number) => ({ rangeEnd: call.start + 2 * blockBytes - 1,
      validator: number === 1 ? '"video-v1"' : '"video-v2"' }),
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => requests.length === 2 && !cache.filePrefetchActive, 'the rejected entity must release its prefetch task');
  await delay(20);
  assert.equal(requests.length, 2);
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, 2 * blockBytes);
  assert.equal(cache.statistics(owner.id).complete, false);
});

test('a foreground seek cancels background prefetch and owns the source until its input closes', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media, requests, open } = await fixture(t, {
    length: 32 * blockBytes,
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1, delayMs: 15 }),
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => requests.length >= 2 && cache.filePrefetchActive, 'background prefetch should start');
  const job = cache.filePrefetchActive;
  const foreground = await cache.open(resource, 'GET', `bytes=${media.length - blockBytes}-${media.length - 1}`,
    '"video-v1"', owner.controller.signal);
  try {
    assert.ok(job.controller.signal.aborted);
    await job.finished;
    const count = requests.length;
    await delay(40);
    assert.equal(requests.length, count);
    assert.equal(cache.foregroundReads, 1);
    assert.equal(cache.filePrefetchActive, null);
  } finally {
    foreground.controller.abort();
    await foreground.response.body?.cancel().catch(() => {});
    foreground.releaseBudget();
  }
});

test('clearing video cache cancels background I/O and does not immediately refill cleared bytes', { timeout: 5000 }, async t => {
  const { cache, owner, requests, open } = await fixture(t, {
    length: 32 * blockBytes,
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1, delayMs: 15 }),
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => requests.length >= 2 && cache.filePrefetchActive, 'background prefetch should start');
  await cache.clearVideos();
  const count = requests.length;
  await delay(40);
  assert.equal(requests.length, count);
  assert.equal(owner.prefetchJobs.size, 0);
  assert.equal(cache.filePrefetchActive, null);
  assert.equal(owner.bytes, 0);
  assert.equal(cache.statistics(owner.id).complete, false);
});

test('releasing playback waits for background prefetch cancellation and removes its disk blocks', { timeout: 5000 }, async t => {
  const { cache, owner, requests, open } = await fixture(t, {
    length: 32 * blockBytes,
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1, delayMs: 15 }),
  });
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => requests.length >= 2 && cache.filePrefetchActive, 'background prefetch should start');
  await cache.release(owner.id);
  const count = requests.length;
  await delay(40);
  assert.equal(requests.length, count);
  assert.ok(requests[1].signal.aborted);
  assert.equal(owner.prefetchJobs.size, 0);
  assert.equal(owner.bytes, 0);
  assert.equal(cache.statistics(owner.id), null);
});

test('background prefetch respects remaining disk capacity without evicting foreground media', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media, open } = await fixture(t, {
    request: call => ({ rangeEnd: call.start + 2 * blockBytes - 1 }),
  });
  owner.maxBytes = 11 * blockBytes; cache.videoMaxBytes = owner.maxBytes;
  const other = cache.resource(owner, 'https://media.example/audio.m4a');
  await cache.put(other, 0, media.subarray(0, blockBytes));
  await cache.put(other, blockBytes, media.subarray(blockBytes, 2 * blockBytes));
  await consume(await open(`bytes=0-${2 * blockBytes - 1}`));
  await waitFor(() => owner.bytes === owner.maxBytes && !cache.filePrefetchActive, 'the background writer must stop at available capacity');
  assert.equal(other.pages.size, 2);
  assert.deepEqual(await cache.read(other, 0, blockBytes - 1, false), media.subarray(0, blockBytes));
  assert.ok(owner.bytes <= owner.maxBytes);
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, media.length - blockBytes);
  assert.equal(cache.statistics(owner.id).complete, false);
  assert.ok(cache.missingFileRange(resource));
});

test('an interrupted forward read resumes its validated bytes before the decoder catches up', { timeout: 5000 }, async t => {
  const { owner, media, requests, open } = await fixture(t, {
    request: (_call, number) => number === 1 ? { cutAt: 2 * blockBytes, error: true } : {},
  });
  const iterator = await open();
  const first = await iterator.next();
  await waitFor(() => owner.bytes === media.length, 'a recoverable upstream interruption must not end pre-reading');
  assert.equal(requests.length, 2);
  // A stream error can discard a queued chunk before the reader stores it.
  assert.ok(requests[1].start > 0 && requests[1].start <= 2 * blockBytes,
    'recovery must resume within the validated prefix sent by the first response');
  assert.equal(requests[1].ifRange, '"video-v1"');
  assert.deepEqual(await consume(iterator, first), media);
});

for (const hls of [false, true]) {
  test(`validated ${hls ? 'HLS' : 'file'} recovery chains short ranges after sustained progress`, { timeout: 10000 }, async t => {
    const { cache, resource, media, requests, open } = await fixture(t, {
      length: 24 * blockBytes,
      request: (call, index) => index === 1 ? { cutAt: 12 * blockBytes, delayMs: 25, error: true }
        : { rangeEnd: Math.min(call.end, call.start + 2 * blockBytes - 1) },
    });
    cache.idleTimeoutMs = 200;
    resource.resumeOnTruncation = hls;
    assert.deepEqual(await consume(await open()), media);
    assert.ok(requests.length >= 6);
    assert.ok(requests.slice(1).every(call => call.ifRange === '"video-v1"'));
  });
}

test('unvalidated interrupted responses are never spliced to a new entity', { timeout: 5000 }, async t => {
  const { requests, open } = await fixture(t, {
    request: () => ({ cutAt: 2 * blockBytes, validator: false }),
  });
  const iterator = await open();
  await assert.rejects(() => consume(iterator), /truncated media response/);
  assert.equal(requests.length, 1);
});

test('a changed entity on resume stops playback without caching its replacement', { timeout: 5000 }, async t => {
  const { owner, requests, open } = await fixture(t, {
    request: (_call, number) => number === 1 ? { cutAt: 2 * blockBytes } : { validator: '"video-v2"' },
  });
  const iterator = await open();
  await assert.rejects(() => consume(iterator), /media changed/);
  assert.equal(requests.length, 2);
  assert.equal(owner.bytes, 2 * blockBytes);
});

test('forward cache stays within its byte budget and closing cancels a blocked reader', { timeout: 5000 }, async t => {
  const { cache, owner, requests, open } = await fixture(t);
  owner.maxBytes = 4 * blockBytes;
  cache.videoMaxBytes = owner.maxBytes;
  const iterator = await open();
  const first = await iterator.next();
  await waitFor(() => owner.bytes === owner.maxBytes, 'pre-reading should reach the configured budget');
  await delay(20);
  assert.ok(owner.bytes <= owner.maxBytes);
  assert.ok(owner.forwardBytes <= owner.maxBytes);
  const before = owner.networkBytes;
  await cache.release(owner.id);
  assert.ok(requests[0].signal.aborted);
  assert.equal(owner.networkBytes, before);
  await assert.rejects(() => consume(iterator, first));
});

test('closing during recovery cancels the retry before it opens another connection', { timeout: 5000 }, async t => {
  const { cache, owner, requests, open } = await fixture(t, {
    request: () => ({ cutAt: 2 * blockBytes }),
  });
  const iterator = await open();
  await iterator.next();
  await waitFor(() => owner.bytes === 2 * blockBytes, 'the received prefix should remain cached');
  await cache.release(owner.id);
  assert.equal(requests.length, 1);
  await assert.rejects(() => consume(iterator));
});

test('cache completion counts unique stored bytes instead of overlapping probe blocks', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media } = await fixture(t);
  cache.accept(resource, new Response(null, { status: 206, headers: {
    'content-range': `bytes 0-${media.length - 1}/${media.length}`,
    'content-length': String(media.length), etag: '"video-v1"',
  } }));
  await cache.put(resource, 0, media.subarray(0, blockBytes));
  await cache.put(resource, blockBytes / 2, media.subarray(blockBytes / 2, blockBytes * 1.5));
  let statistics = cache.statistics(owner.id);
  assert.equal(statistics.bytes, 2 * blockBytes);
  assert.equal(statistics.cachedMediaBytes, 1.5 * blockBytes);
  assert.deepEqual(statistics.cachedRanges, [[0, 0.15]]);
  assert.equal(statistics.mediaBytes, media.length);
  assert.equal(statistics.complete, false);
  await cache.put(resource, 7 * blockBytes, media.subarray(7 * blockBytes, 8 * blockBytes));
  assert.deepEqual(cache.statistics(owner.id).cachedRanges, [[0, 0.15], [0.7, 0.8]]);
  for (let offset = blockBytes; offset < media.length; offset += blockBytes)
    await cache.put(resource, offset, media.subarray(offset, offset + blockBytes));
  statistics = cache.statistics(owner.id);
  assert.equal(statistics.cachedMediaBytes, media.length);
  assert.equal(statistics.complete, true);
  assert.deepEqual(statistics.cachedRanges, [[0, 1]]);
});

test('separate audio must be fully acquired before the playback cache is complete', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media } = await fixture(t);
  const sound = cache.resource(owner, 'https://media.example/audio.m4a');
  sound.forwardCache = true;
  async function store(target, bytes, firstBlock = 0, endBlock = bytes.length / blockBytes) {
    cache.accept(target, new Response(null, { status: 206, headers: {
      'content-range': `bytes 0-${bytes.length - 1}/${bytes.length}`,
      'content-length': String(bytes.length), etag: '"fixture-v1"',
    } }));
    for (let start = firstBlock * blockBytes; start < endBlock * blockBytes; start += blockBytes)
      await cache.put(target, start, bytes.subarray(start, start + blockBytes));
  }
  await store(resource, media, 0, 6);
  assert.equal(cache.statistics(owner.id).complete, false);
  assert.equal(cache.statistics(owner.id).mediaBytes, null);
  assert.deepEqual(cache.statistics(owner.id).cachedRanges, []);
  await store(sound, media.subarray(0, 4 * blockBytes), 2, 4);
  assert.deepEqual(cache.statistics(owner.id).cachedRanges, [[0.5, 0.6]]);
  await store(resource, media, 6);
  await store(sound, media.subarray(0, 4 * blockBytes));
  const statistics = cache.statistics(owner.id);
  assert.equal(statistics.complete, true);
  assert.equal(statistics.cachedMediaBytes, media.length + 4 * blockBytes);
  assert.equal(statistics.mediaBytes, statistics.cachedMediaBytes);
});

test('clearing a fully cached file removes the completion state', { timeout: 5000 }, async t => {
  const { cache, owner, resource, media } = await fixture(t);
  cache.accept(resource, new Response(null, { status: 206, headers: {
    'content-range': `bytes 0-${media.length - 1}/${media.length}`,
    'content-length': String(media.length), etag: '"fixture-v1"',
  } }));
  for (let start = 0; start < media.length; start += blockBytes)
    await cache.put(resource, start, media.subarray(start, start + blockBytes));
  assert.equal(cache.statistics(owner.id).complete, true);
  await cache.clearVideos();
  assert.equal(cache.statistics(owner.id).complete, false);
  assert.equal(cache.statistics(owner.id).cachedMediaBytes, 0);
  assert.deepEqual(cache.statistics(owner.id).cachedRanges, []);
});

test('cache size changes and disabling affect the active playback session', { timeout: 5000 }, async t => {
  const { cache, owner } = await fixture(t);
  for (const sizeGB of [1, 2, 3, 4]) {
    await cache.update({ enabled: true, sizeGB });
    assert.equal(owner.maxBytes, sizeGB * 1024 ** 3);
    assert.equal(cache.videoMaxBytes, owner.maxBytes);
    assert.equal(cache.statistics(owner.id).cacheEnabled, true);
  }
  await cache.update({ enabled: false, sizeGB: 4 });
  assert.equal(cache.statistics(owner.id).cacheEnabled, false);
  assert.equal(owner.maxBytes, 0);
  assert.equal(cache.statistics(owner.id).complete, false);
});

test('a cached manifest never claims that all media segments are complete', { timeout: 5000 }, async t => {
  const { cache, owner, resource } = await fixture(t);
  resource.manifestURL = 'https://media.example/index.m3u8';
  await cache.put(resource, 0, Buffer.from('#EXTM3U\n#EXT-X-ENDLIST\n'));
  const statistics = cache.statistics(owner.id);
  assert.ok(statistics.cachedMediaBytes > 0);
  assert.deepEqual(statistics.cachedRanges, []);
  assert.equal(statistics.mediaBytes, null);
  assert.equal(statistics.complete, false);
});
