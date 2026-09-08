import { createDecipheriv, createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function normalizeKey(input) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const checkAlphabet = alphabet + '*~$=U';
  const key = input.toUpperCase().replace(/[-\s]/g, '');
  if (![17,27].includes(key.length) || [...key.slice(0, -1)].some(c => !alphabet.includes(c))) throw new Error('Invalid key');
  const check = [...key.slice(0, -1)].reduce((n, c) => (n * 32 + alphabet.indexOf(c)) % 37, 0);
  if (checkAlphabet[check] !== key.at(-1)) throw new Error('Invalid key checksum');
  return key;
}

export function decrypt(envelope, userKey, path) {
  if (envelope.v !== 1 || envelope.alg !== 'A256GCM' || envelope.kdf !== 'sha256') throw new Error('Unsupported envelope');
  const normalized = normalizeKey(userKey);
  const key = createHash('sha256').update((normalized.length === 27 ? 'healthmcp/v2:' : 'healthmcp/v1:') + normalized).digest();
  const iv = Buffer.from(envelope.iv, 'base64'), ct = Buffer.from(envelope.ct, 'base64');
  if (iv.length !== 12 || ct.length < 18) throw new Error('Invalid envelope');
  const aes = createDecipheriv('aes-256-gcm', key, iv);
  aes.setAAD(Buffer.from(path, 'utf8')); aes.setAuthTag(ct.subarray(-16));
  const compressed = Buffer.concat([aes.update(ct.subarray(0, -16)), aes.final()]);
  return JSON.parse(gunzipSync(compressed, {maxOutputLength: 64 * 1024 * 1024}));
}

// Download the envelope directly into the sandbox. Never send the key to the server.
// HEALTHMCP_KEY is a sandbox secret, not a tool argument or a key pasted into chat.
if (typeof HEALTHMCP_EMBEDDED === 'undefined' && process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.env.HEALTHMCP_KEY || !process.argv[2] || !process.argv[3]) {
    console.error('Usage: HEALTHMCP_KEY=<sandbox secret> node decrypt.mjs envelope.json <manifest path>');
    process.exit(1);
  }
  const value = decrypt(JSON.parse(readFileSync(process.argv[2], 'utf8')), process.env.HEALTHMCP_KEY, process.argv[3]);
  process.stdout.write(JSON.stringify(value) + '\n');
}
