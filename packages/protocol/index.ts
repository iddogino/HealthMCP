import definitions from './series.json';
export const SERIES = Object.fromEntries(definitions.map(s => [s.id, s]));
export const BASE32 = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const CHECK37 = BASE32 + '*~$=U';
export const MAX_ENVELOPE_BYTES = 16 * 1024 * 1024;
export type Envelope = {v: 1; alg: 'A256GCM'; kdf: 'sha256'; iv: string; ct: string};
export function checksum(payload: string): string {
  if (!/^(?:[0-9A-HJKMNP-TV-Z]{16}|[0-9A-HJKMNP-TV-Z]{26})$/.test(payload)) throw new Error('Invalid key characters');
  return CHECK37[[...payload].reduce((sum, c) => (sum * 32 + BASE32.indexOf(c)) % 37, 0)];
}
export function normalizeKey(key: string): string {
  const s = key.toUpperCase().replace(/[-\s]/g, '');
  if (![17,27].includes(s.length) || checksum(s.slice(0, -1)) !== s.at(-1)) throw new Error('Invalid key checksum');
  return s;
}
export function formatKey(key: string): string {
  const s = normalizeKey(key);
  return s.slice(0,-1).match(/.{1,4}/g)!.join('-')+'-'+s.at(-1);
}
export function validDay(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0,10) === value && value >= '1900-01-01' && value <= '2200-12-31';
}
export function validatePeriod(series: string, period: string): boolean {
  if (series === 'check' || series === 'profile') return period === 'single';
  const def = SERIES[series];
  if (!def) return false;
  if (def.chunk === 'month') return /^\d{4}-\d{2}$/.test(period) && validDay(period + '-01');
  if (def.chunk === 'record') {
    const [day, uuid, ...rest] = period.split('/');
    return !rest.length && validDay(day) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(uuid ?? '');
  }
  return validDay(period);
}
export function objectPath(userId: string, series: string, period: string): string {
  if (!/^u_[0-9a-f-]{36}$/.test(userId) || !validatePeriod(series, period)) throw new Error('Invalid object coordinates');
  return series === 'check' || series === 'profile' ? `${userId}/${series}` : `${userId}/${series}/${period}`;
}
export function validateEnvelope(value: unknown): value is Envelope {
  if (!value || typeof value !== 'object') return false;
  const e = value as Envelope;
  if (Object.keys(e).sort().join(',') !== 'alg,ct,iv,kdf,v' || e.v !== 1 || e.alg !== 'A256GCM' || e.kdf !== 'sha256') return false;
  try {
    return typeof e.iv === 'string' && typeof e.ct === 'string' && /^[A-Za-z0-9+/]{16}$/.test(e.iv) && /^[A-Za-z0-9+/]+={0,2}$/.test(e.ct) && e.ct.length % 4 === 0 && atob(e.iv).length === 12 && atob(e.ct).length >= 18;
  } catch { return false; }
}
export function canonicalRequest(method: string, target: string, timestamp: string, nonce: string, bodyHash: string): string {
  return [method.toUpperCase(), target, timestamp, nonce, bodyHash].join('\n');
}
