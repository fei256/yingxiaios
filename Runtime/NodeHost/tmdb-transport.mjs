import { fetchBuffer } from './parity/lib/http.mjs';
import { proxyUrl } from './parity/lib/proxy-settings.mjs';
import { setTimeout as delay } from 'node:timers/promises';

// Per-request configuration prevents one retained settings page from changing
// another service, and never retains authenticated proxy connections.
export async function fetchTMDB(params, signal) {
  let url;
  try { url = new URL(params.url); } catch { throw new Error('TMDB 地址无效'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hash)
    throw new Error('TMDB 地址无效');
  const proxy = params.proxy ? {
    url: proxyUrl(params.proxy.url),
    username: String(params.proxy.username || ''), password: String(params.proxy.password || ''),
  } : undefined;
  const timeoutMs = Math.max(1000, Math.min(30_000, Number(params.timeoutMs) || 30_000));
  for (let attempt = 0; attempt < 2; attempt++) {
    signal?.throwIfAborted();
    try {
      const data = await fetchBuffer(url.toString(), {
        proxy, headers: params.headers || {}, signal, timeoutMs,
        maxBytes: 24 * 1024 * 1024, label: 'TMDB',
      });
      return { data: data.toString('base64') };
    } catch (error) {
      signal?.throwIfAborted();
      if (attempt || ![429, 502, 503, 504].includes(error.httpStatus)) throw error;
      await delay(500, undefined, { signal });
    }
  }
}
