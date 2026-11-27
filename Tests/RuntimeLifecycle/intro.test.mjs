import assert from 'node:assert/strict';
import test from 'node:test';
import { MobileServices } from '../../Runtime/NodeHost/mobile-services.mjs';
import { IntroSkip } from '../../Runtime/NodeHost/remote-skip.mjs';

const identity = { mediaType: 'tv', tmdbId: 15, season: 1, episode: 3 };
const metadata = { imdbId: 'tt123' };
const input = { identity, metadata, duration: 1200, sessionId: 'current', mediaVersion: 0 };
const record = { tmdb_id: 15, season: 1, episode: 3, duration_sec: 1200,
  intro: { start_sec: 30, end_sec: 90 }, credits: { start_sec: 1100, end_sec: 1190 } };

function fixture(fetchJson) {
  const service = Object.create(MobileServices.prototype);
  service.session = { id: input.sessionId, mediaVersion: 0 };
  service.operations = new Map();
  service.introSkip = new IntroSkip({ fetchJson });
  return service;
}

test('fast verified provider returns while the other lookup is still pending', async () => {
  let finish;
  const slow = new Promise(resolve => { finish = resolve; });
  const service = fixture(async url => new URL(url).hostname === 'api.theintrodb.org' ? record : slow);
  const pending = service.dispatch('intro.plan', { ...input, provider: 'introdb' }, 'slow');
  try {
    const { segments } = await service.dispatch('intro.plan', { ...input, provider: 'theintrodb' }, 'fast');
    assert.deepEqual(segments.map(({ start, end }) => [start, end]), [[30, 90], [1100, 1190]]);
    assert.ok(service.operations.has('slow'));
    service.session = { id: 'next', mediaVersion: 0 };
  } finally { finish(record); }
  await assert.rejects(pending, /播放媒体已改变/);
});

test('prefetch warms one episode without changing the active session or trusting a different cut', async () => {
  const urls = [];
  const service = fixture(async url => { urls.push(url); return record; });
  const active = service.session;
  const warm = await service.dispatch('intro.prefetch', { identity, metadata }, 'prefetch');
  assert.deepEqual(warm.plans.map(plan => [plan.duration, plan.segments[0].end]), [[1200, 90]]);
  assert.equal(service.session, active);
  assert.equal(urls.length, 2);
  service.session = { id: 'next', mediaVersion: 0 };
  const options = { ...input, sessionId: 'next', provider: 'theintrodb' };
  assert.equal((await service.dispatch('intro.plan', options, 'match')).segments[0].start, 30);
  assert.deepEqual((await service.dispatch('intro.plan', { ...options, duration: 650 }, 'cut')).segments, []);
  assert.equal(urls.length, 2);
  const otherEpisode = { ...identity, episode: 4 };
  assert.deepEqual((await service.dispatch('intro.plan', { ...options, identity: otherEpisode }, 'other')).segments, []);
  assert.equal(urls.length, 3);
});

test('manual and chapter intervals win, and a failed provider can be retried', async () => {
  let calls = 0;
  const service = fixture(async () => { if (++calls === 1) throw new Error('offline'); return record; });
  const options = { ...input, provider: 'theintrodb', preferences: { openingOverride: 55 },
    chapters: [{ title: 'OP', time: 20, end: 70 }] };
  const local = await service.dispatch('intro.plan', options);
  assert.ok(local.retryable);
  assert.deepEqual(local.segments.map(row => [row.source, row.end]), [['手动', 55]]);
  const recovered = await service.dispatch('intro.plan', { ...options, preferences: {} });
  assert.deepEqual(recovered.segments.map(row => [row.source, row.end]), [['章节', 70], ['TheIntroDB', 1190]]);
});

test('unidentified next episodes do not issue lookups, cancelled prefetch can be retried', async () => {
  let calls = 0;
  const service = fixture(async (_url, signal) => {
    if (++calls > 1) return record;
    return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
  });
  await service.dispatch('intro.prefetch', { identity: { ...identity, episode: 0 } });
  assert.equal(calls, 0);
  const pending = service.dispatch('intro.prefetch', { identity }, 'warming');
  await service.dispatch('operation.cancel', { id: 'warming' });
  await assert.rejects(pending);
  const fresh = await service.dispatch('intro.plan', { ...input, provider: 'theintrodb' });
  assert.equal(fresh.segments.length, 2);
  assert.equal(calls, 2);
});
