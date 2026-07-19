# 🔌 Wiring an App to Self-Hosted Supabase (v3)

Quick guide for app teams: getting your app connected to this self-hosted Supabase instance.

> **Three things to do. ~10 minutes total.**

> **Note on Step 2:** the `apps.json` / secret-mapping pattern below is one example of a config-driven deploy pipeline (App Service + a pipeline that reads a JSON manifest and injects Key Vault secrets as env vars). This repo doesn't include that pipeline — swap it for however your own CI/CD injects environment variables and secrets into App Service (GitHub Actions, Azure DevOps YAML, Bicep/Terraform app config, etc.). The parts that matter regardless of pipeline: VNet integration (Step 1) and the three env vars themselves (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`).

---

## Step 1 — Get VNet integration enabled (one-time, via DevOps)

Your App Service needs to be VNet-integrated with the Supabase VNet. **Ask DevOps to enable this** — they'll click through the portal in about 30 seconds:

```
App Service → your app → Networking → Outbound traffic → VNet integration
  Add VNet:  supabase-vnet
  Subnet:    snet-appservice  (10.50.32.0/22, delegated)
```

After this, your app can reach Supabase over the private VNet. **Without this step, your app cannot connect — it'll just time out.**

> 💡 You can verify it's enabled by going to your App Service → Networking and checking the "VNet integration" status reads "Connected".

---

## Step 2 — Update your `apps.json`

Add the Supabase config to your repo's `apps.json`:

```json
{
  "$schema": "./apps.schema.json",
  "port": 3000,

  "envVars": {
    "NODE_ENV": "production",
    "SUPABASE_URL": "http://10.50.10.4:8000"
  },

  "secretMappings": {
    "SUPABASE_ANON_KEY":    "SUPABASE-ANON-KEY",
    "SUPABASE_SERVICE_KEY": "SUPABASE-SERVICE-KEY"
  }
}
```

Three things to know:

| Field | Notes |
|---|---|
| `SUPABASE_URL` | The Supabase VM's private IP (10.50.10.4). Same for all apps. |
| `SUPABASE_ANON_KEY` | Public key. RLS-limited. Safe to expose to clients. |
| `SUPABASE_SERVICE_KEY` | **God-mode key.** Bypasses Row Level Security. **Backend-only.** Never expose to a browser. |

The pipeline pulls these secrets from Key Vault at deploy time and injects them as env vars into your container.

---

## Step 3 — Use the Supabase SDK in your code

It's exactly the same code you'd write for Supabase Cloud:

### Node.js / TypeScript

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_ANON_KEY  // or SUPABASE_SERVICE_KEY for backend operations
)

// Queries
const { data, error } = await supabase
  .from('products')
  .select('*')
  .eq('category', 'shoes')

// Auth
await supabase.auth.signInWithPassword({ email, password })

// Storage
await supabase.storage.from('avatars').upload('user1.jpg', file)

// Realtime
supabase.channel('chat')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' }, console.log)
  .subscribe()
```

### Python

```python
from supabase import create_client
import os

supabase = create_client(
    os.environ["SUPABASE_URL"],
    os.environ["SUPABASE_ANON_KEY"]
)

response = supabase.table("products").select("*").execute()
```

### Java / .NET / Go

The Supabase JS/Python clients are most polished, but any HTTP client + JWT can talk to PostgREST/GoTrue/Storage directly. See [Supabase REST docs](https://supabase.com/docs/guides/api).

---

## ✅ Deploy and Verify

After your `apps.json` changes are merged:

```bash
git push   # triggers whatever CI/CD deploy pipeline your app uses
```

### Add a healthcheck endpoint to confirm wiring

```javascript
// Node.js / Express
app.get('/healthz/supabase', async (req, res) => {
  try {
    const r = await fetch(`${process.env.SUPABASE_URL}/auth/v1/health`);
    const body = await r.text();
    res.json({ ok: r.ok, status: r.status, body });
  } catch (e) {
    res.status(502).json({ error: String(e) });
  }
});
```

Then visit `https://<your-app>.azurewebsites.net/healthz/supabase`. Expected response:

```json
{ "ok": true, "status": 200, "body": "{\"version\":\"vunspecified\",...}" }
```

If you get a 502 or timeout, see **[DEVELOPER-ACCESS.md → Troubleshooting](./DEVELOPER-ACCESS.md#-troubleshooting)**.

---

## 🤔 Common Questions

### "Should I use anon key or service key?"

| Use the **anon key** when | Use the **service key** when |
|---|---|
| Code might run in a browser | Code runs only server-side, never reaches a client |
| User-context operations (RLS-aware queries) | Background jobs, admin tasks, system imports |
| Standard CRUD with logged-in users | Cron jobs that need to read/write any user's data |

When in doubt, use the **anon key** + proper Row Level Security policies.

### "Where do I add new tables?"

Three options, listed best to worst:

1. **Migration file in your repo** (`db/migrations/0001_create_x.sql`) — reviewable in a PR, repeatable, the right answer
2. **Studio dashboard via SSH tunnel** — fine for prototyping; export to SQL afterward and commit it
3. **Direct psql via SSH tunnel** — for one-offs and emergencies

The platform doesn't (yet) have an automated migration pipeline. For now, schema changes happen via path 2 or 3 — but write them down in `db/migrations/` for the record.

### "How do I see what's in the database?"

Open Studio via SSH tunnel — see **[DEVELOPER-ACCESS.md § B](./DEVELOPER-ACCESS.md#b-opening-studio-via-ssh-tunnel)** for the command. Then `http://localhost:3000` in your browser.

### "Is my data isolated from other apps' data?"

By default, **no — all apps share one Supabase project**. Isolation happens at three levels you can use:

- **Schemas** — give each app its own Postgres schema (`app_customer_a`, `app_customer_b`). This is the recommended pattern for multi-app isolation within one shared instance.
- **RLS policies** — tie rows to app identifiers (`app_id` column) if you must share a schema
- **Separate Supabase deployments** — if you need hard isolation, run another VM

#### Recommended naming convention

```sql
-- Each app gets a schema named after the app
CREATE SCHEMA app_customer_a;
GRANT USAGE ON SCHEMA app_customer_a TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA app_customer_a
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA app_customer_a
  GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA app_customer_a
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- Tell PostgREST to expose this schema (one-time edit to compose .env)
-- PGRST_DB_SCHEMAS=public,storage,graphql_public,app_customer_a
```

Talk to DevOps about which approach fits your data sensitivity. For most apps, schema isolation is plenty.

### "Will my data survive Supabase upgrades / restarts?"

Yes. Postgres data and uploaded files live in Docker named volumes whose physical storage is on a separate managed disk. That disk:
- Has `prevent_destroy` in Terraform
- Is snapshotted daily
- Survives container restarts, redeploys, VM reboots, and even VM recreation

See `./scripts/verify-persistence.sh` for the proof-test.

### "What about RLS?"

RLS (Row Level Security) is **mandatory** for any table accessible by `anon` or `authenticated`. Without it, the anon key has full access to everything in your schema. Use the `auth.uid()` helper for user-scoped policies:

```sql
ALTER TABLE app_customer_a.posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users own their posts" ON app_customer_a.posts
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
```

The `service_role` bypasses RLS automatically (via the `BYPASSRLS` attribute), so backend code with the service key sees everything.

---

## 🔗 Related Docs

- **[DEVELOPER-ACCESS.md](./DEVELOPER-ACCESS.md)** — SSH tunnel setup, Studio access, troubleshooting
- **Supabase official docs** — https://supabase.com/docs — most of it applies as-is to this self-hosted instance

---

*Maintained by whoever owns this deployment — update this line once you fork the repo for your own team.*
