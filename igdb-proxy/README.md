# igdb-proxy

A private Cloudflare Worker that lets GameShelf query IGDB without each user needing Twitch credentials.

```
App ──POST /v4/games (Bearer APP_KEY)──▶ Worker ──POST (Client-ID + app token)──▶ api.igdb.com
                                          │
                                          ├─ Twitch app token cached in KV (~60-day lifetime)
                                          ├─ 401 → refresh token once and retry
                                          ├─ 429 → back off and retry (up to 4 attempts)
                                          └─ 200 responses cached for 7 days (Cache API, best-effort)
```

Images aren't proxied. Load them straight from `https://images.igdb.com/igdb/image/upload/t_cover_big/{image_id}.jpg`.

## One-time setup

1. **Create a Twitch app:** go to <https://dev.twitch.tv/console/apps> and click Register Your Application.
   - Set the OAuth redirect URL to `http://localhost` (it isn't used).
   - Pick any category and set the client type to **Confidential**.
   - Copy the Client ID, then generate a Client Secret.
   - Twitch requires two-factor authentication on the account.
2. **Install Node.js** (LTS from <https://nodejs.org>), then from this folder run:

   ```bash
   npm install
   ```

   ```bash
   npx wrangler login
   ```

   ```bash
   npx wrangler kv namespace create TOKENS
   ```

   Paste the printed `id` into `wrangler.jsonc`.
3. **Set the secrets.** You'll be prompted for each value:

   ```bash
   npx wrangler secret put TWITCH_CLIENT_ID
   ```

   ```bash
   npx wrangler secret put TWITCH_CLIENT_SECRET
   ```

   ```bash
   npx wrangler secret put APP_KEY
   ```

   `APP_KEY` is any long random string, for example from `openssl rand -hex 32`. You and your brother both put it in the app's settings.
4. **Deploy:**

   ```bash
   npm run deploy
   ```

## Try it

```bash
curl -s https://igdb-proxy.<your-subdomain>.workers.dev/v4/games -H "Authorization: Bearer $APP_KEY" -d 'search "hollow knight"; fields name,first_release_date,cover.image_id; limit 5;'
```

Response headers include `X-Proxy-Cache: HIT|MISS`. Send `Cache-Control: no-cache` to bypass the cache.

## Notes

- The Cache API is a no-op on some `*.workers.dev` setups. If caching matters, add a custom domain. Everything still works without the cache.
- IGDB's API is free for non-commercial use, with attribution. That's fine for personal use.
- Allowed endpoints are listed in `ALLOWED_ENDPOINTS` in `src/index.ts`.
- Local development: copy `.dev.vars.example` to `.dev.vars`, then run `npm run dev`.
