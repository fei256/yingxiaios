import assert from 'node:assert/strict';
import test from 'node:test';
import { MobileServices } from '../../Runtime/NodeHost/mobile-services.mjs';
import { AISubtitleService } from '../../Runtime/NodeHost/parity/lib/ai-subtitles.mjs';

const aiConfig = {
  enabled: true, endpoint: 'https://ai.fixture.invalid/v1', protocol: 'chat', model: 'fixture-model',
  apiKey: 'fixture-key', targetLanguage: 'zh-CN', transcriptionModel: 'whisper-1',
};
const scope = { sessionId: 'fixture-session', mediaVersion: 0, timelineVersion: 0 };
const translation = { choices: [{ message: { content: '有效译文' } }] };

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
async function service(json = async () => translation) {
  // The constructor starts real cache services. Only those I/O dependencies are
  // replaced; settingsSnapshot, settings.set and AI requests run production code.
  const value = Object.create(MobileServices.prototype);
  value.configuration = {}; value.revision = 0; value.aiRevision = 0;
  value.cache = { update: async () => {} };
  value.session = { id: scope.sessionId, mediaVersion: 0, timelineVersion: 0 };
  value.settings = { private: async () => value.settingsSnapshot() };
  value.ai = new AISubtitleService(value.settings, () => value.session, { json });
  await value.call('settings.set', {
    ai: structuredClone(aiConfig),
    tmdb: { panApiBase: 'https://pan.fixture.invalid', panToken: 'fixture-pan-key' },
    subtitles: { assrtToken: 'fixture-subtitle-key' },
  });
  return value;
}
async function pendingRequest(method = 'ai.translate', extra = { text: 'Hello' }, reply = translation) {
  const entered = deferred(), response = deferred();
  const value = await service(async () => { entered.resolve(); await response.promise; return reply; });
  const pending = value.call(method, { ...scope, ...extra }).then(
    result => ({ result }), error => ({ error }),
  );
  await entered.promise;
  return { value, pending, release: response.resolve };
}

for (const [name, patch] of [
  ['video cache changes', { videoCache: { enabled: true, sizeGB: 2 } }],
  ['pan search changes', { tmdb: { panConcurrency: '3' } }],
  ['online subtitle changes', { subtitles: { language: 'en' } }],
  ['identical AI settings', { ai: structuredClone(aiConfig) }],
  ['empty AI patch', { ai: {} }],
]) {
  test(`${name} preserve an in-flight translation`, { timeout: 5000 }, async () => {
    const { value, pending, release } = await pendingRequest();
    const before = value.settingsSnapshot();
    await value.call('settings.set', patch);
    assert.deepEqual(value.configuration.ai, before.ai);
    assert.equal(value.aiRevision, before.aiRevision);
    release();
    const { result, error } = await pending;
    assert.equal(error, undefined);
    assert.deepEqual(result, { text: '有效译文' });
  });
}

test('a changed AI model rejects an in-flight result', { timeout: 5000 }, async () => {
  const { value, pending, release } = await pendingRequest();
  const before = value.aiRevision;
  await value.call('settings.set', { ai: { model: 'new-model' } });
  assert.equal(value.aiRevision, before + 1);
  assert.equal(value.configuration.ai.endpoint, aiConfig.endpoint);
  assert.equal(value.configuration.ai.apiKey, aiConfig.apiKey);
  release();
  const { error } = await pending;
  assert.equal(error?.code, 'AI_STALE');
});

test('turning AI off rejects the prior enabled request', { timeout: 5000 }, async () => {
  const { value, pending, release } = await pendingRequest();
  await value.call('settings.set', { ai: { enabled: false } });
  release();
  assert.equal((await pending).error?.code, 'AI_STALE');
});

test('repeated settings applications preserve translation cache entries', async () => {
  let requests = 0;
  const value = await service(async () => { requests++; return translation; });
  const first = await value.call('ai.translate', { ...scope, text: 'Same subtitle' });
  await value.call('settings.set', { ai: structuredClone(aiConfig) });
  await value.call('settings.set', { videoCache: { enabled: false, sizeGB: 4 } });
  await value.call('settings.set', { tmdb: { panCheckLinks: false } });
  const second = await value.call('ai.translate', { ...scope, text: 'Same subtitle' });
  assert.deepEqual(second, first);
  assert.equal(requests, 1, 'the second result must come from the production AI cache');
});

test('reordered AI properties do not invalidate requests or cache', async () => {
  const value = await service();
  const before = value.aiRevision;
  const reordered = Object.fromEntries(Object.entries(value.configuration.ai).reverse());
  await value.call('settings.set', { ai: reordered });
  assert.equal(value.aiRevision, before);
});

test('partial settings patches keep unedited fields in every section', async () => {
  const requests = [];
  const value = await service(async (url, options) => { requests.push({ url, options }); return translation; });
  await value.call('settings.set', { ai: { model: 'edited-model' }, tmdb: { panCheckLinks: false }, subtitles: { language: 'en' } });
  assert.equal(value.configuration.ai.apiKey, 'fixture-key');
  assert.equal(value.configuration.ai.endpoint, aiConfig.endpoint);
  assert.equal(value.configuration.ai.targetLanguage, 'zh-CN');
  assert.equal(value.configuration.tmdb.panApiBase, 'https://pan.fixture.invalid');
  assert.equal(value.configuration.tmdb.panToken, 'fixture-pan-key');
  assert.equal(value.configuration.subtitles.assrtToken, 'fixture-subtitle-key');
  assert.equal(value.configuration.subtitles.xunlei, true);
  await value.call('ai.translate', { ...scope, text: 'Use the edited model' });
  assert.equal(requests[0].options.json.model, 'edited-model');
  assert.equal(requests[0].options.headers.Authorization, 'Bearer fixture-key');
  assert.equal(new URL(requests[0].url).pathname, '/v1/chat/completions');
});

test('cache changes preserve an in-flight speech transcription', { timeout: 5000 }, async () => {
  const wav = Buffer.alloc(46); wav.write('RIFF'); wav.write('WAVE', 8);
  const { value, pending, release } = await pendingRequest('ai.transcribe', {
    position: 12, duration: 1, audio: wav.toString('base64'),
  }, { segments: [{ start: 0, end: 1, text: '语音原文' }] });
  const before = value.aiRevision;
  await value.call('settings.set', { videoCache: { enabled: false, sizeGB: 1 } });
  assert.equal(value.aiRevision, before);
  release();
  const { result, error } = await pending;
  assert.equal(error, undefined);
  assert.deepEqual(result, { cues: [{ start: 12, end: 13, text: '语音原文' }] });
});

test('reverting changed AI configuration still rejects work from the older epoch', { timeout: 5000 }, async () => {
  const { value, pending, release } = await pendingRequest();
  await value.call('settings.set', { ai: { model: 'temporary-model' } });
  await value.call('settings.set', { ai: { model: aiConfig.model } });
  release();
  assert.equal((await pending).error?.code, 'AI_STALE');
});
