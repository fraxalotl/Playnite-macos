/**
 * Private IGDB proxy.
 *
 * The app sends `POST /v4/{endpoint}` with an Apicalypse query body and
 * `Authorization: Bearer <APP_KEY>`. The Worker swaps that for a Twitch app
 * access token, forwards to api.igdb.com, retries rate-limited requests and
 * caches successful responses.
 */

export interface Env {
  TWITCH_CLIENT_ID: string;
  TWITCH_CLIENT_SECRET: string;
  APP_KEY: string;
  TOKENS: KVNamespace;
  /** Optional override, seconds. Defaults to 7 days. */
  CACHE_TTL_SECONDS?: string;
}

const IGDB_BASE = "https://api.igdb.com/v4";
const TWITCH_TOKEN_URL = "https://id.twitch.tv/oauth2/token";
const TOKEN_KV_KEY = "twitch_app_token";
const MAX_BODY_BYTES = 16 * 1024;
const MAX_ATTEMPTS = 4;

/** Endpoints the app is allowed to query. */
export const ALLOWED_ENDPOINTS = new Set([
  "age_ratings",
  "alternative_names",
  "artworks",
  "collections",
  "companies",
  "covers",
  "external_games",
  "franchises",
  "game_modes",
  "game_videos",
  "games",
  "genres",
  "involved_companies",
  "keywords",
  "multiquery",
  "platforms",
  "player_perspectives",
  "release_dates",
  "screenshots",
  "search",
  "themes",
  "websites",
]);

interface CachedToken {
  accessToken: string;
  /** Epoch milliseconds. */
  expiresAt: number;
}

// Per-isolate memo so most requests skip the KV read.
let memoToken: CachedToken | null = null;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await handle(request, env, ctx);
    } catch (err) {
      console.error("Unhandled error", err);
      return json({ error: "internal_error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function handle(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/health") {
    return json({ ok: true });
  }

  if (!(await isAuthorized(request, env))) {
    return json({ error: "unauthorized" }, 401);
  }

  const match = /^\/v4\/([a-z_]+)\/?$/.exec(url.pathname);
  if (!match) {
    return json({ error: "not_found" }, 404);
  }
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405, { Allow: "POST" });
  }

  const endpoint = match[1];
  if (!ALLOWED_ENDPOINTS.has(endpoint)) {
    return json({ error: "endpoint_not_allowed", endpoint }, 403);
  }

  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) {
    return json({ error: "query_too_large" }, 413);
  }

  const bypassCache = request.headers.get("Cache-Control")?.includes("no-cache") ?? false;
  const cacheKey = await makeCacheKey(url.origin, endpoint, body);
  const cache = getCache();

  if (cache && !bypassCache) {
    const hit = await cache.match(cacheKey).catch(() => undefined);
    if (hit) {
      const res = new Response(hit.body, hit);
      res.headers.set("X-Proxy-Cache", "HIT");
      return res;
    }
  }

  const upstream = await queryIgdb(env, endpoint, body);
  const text = await upstream.text();
  const res = new Response(text, {
    status: upstream.status,
    headers: {
      "Content-Type": upstream.headers.get("Content-Type") ?? "application/json",
      "X-Proxy-Cache": "MISS",
    },
  });

  if (cache && upstream.ok) {
    const ttl = Number(env.CACHE_TTL_SECONDS ?? 7 * 24 * 3600);
    const toCache = new Response(text, {
      status: 200,
      headers: {
        "Content-Type": res.headers.get("Content-Type")!,
        "Cache-Control": `public, max-age=${ttl}`,
      },
    });
    ctx.waitUntil(cache.put(cacheKey, toCache).catch(() => undefined));
  }

  return res;
}

/** Forward a query to IGDB, refreshing the token on 401 and backing off on 429. */
async function queryIgdb(env: Env, endpoint: string, body: string): Promise<Response> {
  let token = await getToken(env, false);
  let refreshed = false;

  for (let attempt = 1; ; attempt++) {
    const res = await fetch(`${IGDB_BASE}/${endpoint}`, {
      method: "POST",
      headers: {
        "Client-ID": env.TWITCH_CLIENT_ID,
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Content-Type": "text/plain",
      },
      body,
    });

    if (res.status === 401 && !refreshed) {
      refreshed = true;
      token = await getToken(env, true);
      continue;
    }

    if (res.status === 429 && attempt < MAX_ATTEMPTS) {
      const retryAfter = Number(res.headers.get("Retry-After"));
      const delay = Number.isFinite(retryAfter) && retryAfter > 0
        ? retryAfter * 1000
        : 250 * 2 ** (attempt - 1) + Math.random() * 100;
      await sleep(Math.min(delay, 4000));
      continue;
    }

    return res;
  }
}

/** Returns a valid Twitch app access token, using memo → KV → Twitch in that order. */
async function getToken(env: Env, forceRefresh: boolean): Promise<string> {
  const now = Date.now();
  const marginMs = 5 * 60 * 1000;

  if (!forceRefresh) {
    if (memoToken && memoToken.expiresAt - marginMs > now) {
      return memoToken.accessToken;
    }
    const stored = await env.TOKENS.get<CachedToken>(TOKEN_KV_KEY, "json");
    if (stored && stored.expiresAt - marginMs > now) {
      memoToken = stored;
      return stored.accessToken;
    }
  }

  const params = new URLSearchParams({
    client_id: env.TWITCH_CLIENT_ID,
    client_secret: env.TWITCH_CLIENT_SECRET,
    grant_type: "client_credentials",
  });
  const res = await fetch(TWITCH_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  if (!res.ok) {
    throw new Error(`Twitch token request failed: ${res.status} ${await res.text()}`);
  }
  const data = (await res.json()) as { access_token: string; expires_in: number };
  const token: CachedToken = {
    accessToken: data.access_token,
    expiresAt: now + data.expires_in * 1000,
  };
  memoToken = token;
  await env.TOKENS.put(TOKEN_KV_KEY, JSON.stringify(token), {
    // KV requires at least 60 s.
    expirationTtl: Math.max(60, data.expires_in - 3600),
  });
  return token.accessToken;
}

async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!env.APP_KEY || !presented) return false;

  const enc = new TextEncoder();
  const a = enc.encode(presented);
  const b = enc.encode(env.APP_KEY);
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}

/** The Cache API only keys on GET URLs, so hash the POST body into a synthetic URL. */
async function makeCacheKey(origin: string, endpoint: string, body: string): Promise<Request> {
  const normalized = body.replace(/\s+/g, " ").trim();
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${endpoint}\n${normalized}`));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return new Request(`${origin}/__cache/v4/${endpoint}/${hex}`, { method: "GET" });
}

function getCache(): Cache | null {
  try {
    return caches.default;
  } catch {
    return null;
  }
}

function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
