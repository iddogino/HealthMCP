import type {OAuthHelpers} from '@cloudflare/workers-oauth-provider';
export interface Env {
  DB: D1Database;
  BLOBS: R2Bucket;
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  BLOB_SIGNING_SECRET: string;
  PUBLIC_ORIGIN: string;
  APP_TEAM_ID: string;
  APP_BUNDLE_ID: string;
  APNS_KEY_ID?: string;
  APNS_SANDBOX_KEY_ID?: string;
  APNS_SANDBOX_PRIVATE_KEY?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
}
export interface User {
  id: string; device_pubkey: string; created_at: number;
  apns_token: string | null; apns_environment: string;
  last_sync_request_at:number|null; last_synced_at: number | null; cache_generation: number; state: string;
  pending_sync_at: number | null; last_visible_push_at: number | null; last_push_status: string | null;
}
export interface AuthProps { userId: string; connectionId: string; scope: string[] }
export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export const now = () => Math.floor(Date.now() / 1000);
export const json = (body: unknown, status = 200) => Response.json(body, {status, headers: {'Cache-Control': 'no-store'}});
