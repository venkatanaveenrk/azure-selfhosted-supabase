# 🔐 Developer Access Guide — Self-Hosted Supabase (v3)

How to connect to the  self-hosted Supabase platform.

> **TL;DR**
> - **Building features?** You don't need any VM access — your App Service reaches Supabase privately over the VNet. Just use the Supabase SDK with the URL + anon key.
> - **Need Studio dashboard or psql?** Use an SSH tunnel from Cloud Shell (no VPN required).

---

## 📋 Table of Contents

1. [The Two Kinds of "Access"](#-the-two-kinds-of-access)
2. [Using Supabase from your app](#a-using-supabase-from-your-app-the-most-common-case)
3. [Opening Studio via SSH tunnel](#b-opening-studio-via-ssh-tunnel)
4. [Working with the database](#c-working-with-the-database)
5. [Troubleshooting](#-troubleshooting)

---

## 🎯 The Two Kinds of "Access"

| What you want to do | Path | Setup |
|---|---|---|
| **Build app features** (queries, auth, storage) | Supabase SDK with `SUPABASE_URL` + `SUPABASE_ANON_KEY` | VNet integration on App Service (one-time) |
| **Open Studio dashboard** to browse data / run SQL | SSH tunnel via Cloud Shell | None — uses Azure AD |
| **Connect psql / pgAdmin** directly to the DB | SSH tunnel via Cloud Shell (`-L 5432`) | None — uses Azure AD |
| **Apply schema migrations** | SQL files in your app's repo (pipeline applies them) | None |

Day-to-day app development needs **zero** direct VM access. The SSH tunnel is for occasional dashboard work.

---

## A. Using Supabase From Your App (the most common case)

Your app on App Service reaches Supabase **privately over the VNet**. As an app team, you do three things:

### 1. Enable VNet integration on your App Service (one-time, by DevOps)

Your App Service must be VNet-integrated to the Supabase VNet. DevOps does this once per app:

```
Azure Portal → App Service → Networking → Outbound traffic → VNet integration
  Add VNet:  supabase-vnet
  Subnet:    snet-appservice  (10.50.32.0/22, delegated)
```

That's a one-time toggle. After it's done, your app can reach `10.50.10.x` privately.

### 2. Add Supabase config to your app's deploy config

> The `apps.json` example below is a stand-in for whatever config-driven deploy pipeline your app uses. This repo doesn't ship that pipeline — the point is just that `SUPABASE_URL` becomes an env var and the two keys get injected as secrets at deploy time, however your CI/CD does that.

```json
{
  "$schema": "./apps.schema.json",
  "port": 3000,
  "envVars": {
    "SUPABASE_URL": "http://10.50.10.4:8000"
  },
  "secretMappings": {
    "SUPABASE_ANON_KEY":    "SUPABASE-ANON-KEY",
    "SUPABASE_SERVICE_KEY": "SUPABASE-SERVICE-KEY"
  }
}
```

- `SUPABASE_URL` is the VM's private IP — confirm with DevOps (Terraform output `vm_private_ip`)
- The two keys live in Key Vault; the pipeline injects them as env vars at deploy time
- **Only use `SUPABASE_SERVICE_KEY` for backend-only operations** — it bypasses Row Level Security

### 3. Use the Supabase SDK in your code

It's exactly the same as Supabase Cloud:

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_ANON_KEY
)

// Queries, auth, storage, realtime — all work the same way
const { data, error } = await supabase
  .from('products')
  .select('*')
```

```python
from supabase import create_client
supabase = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_ANON_KEY"])
data = supabase.table("products").select("*").execute()
```

From your code's perspective, Supabase Cloud and this self-hosted one are indistinguishable.

### 4. Add a healthcheck endpoint (recommended)

To validate the VNet integration is working, add a `/healthz/supabase` endpoint that calls the Supabase Auth health endpoint:

```javascript
// Node.js / Express
app.get('/healthz/supabase', async (req, res) => {
  try {
    const r = await fetch(`${process.env.SUPABASE_URL}/auth/v1/health`);
    res.json({ ok: r.ok, status: r.status });
  } catch (e) {
    res.status(502).json({ error: String(e) });
  }
});
```

Then hit `https://<your-app>.azurewebsites.net/healthz/supabase` after deploy. A 200 response with `{ok:true, status:200}` confirms the VNet path is good.

---

## B. Opening Studio via SSH Tunnel

You only need this if you want to **open the Studio dashboard** or **connect a database tool** like pgAdmin/DBeaver/psql.

Studio is published only on the VM's loopback (`127.0.0.1:3000`). We reach it by tunneling SSH through Azure AD.

### Prerequisites

- A public IP attached to the VM's NIC (DevOps can attach/detach as needed; usually attached)
- SSH port 22 temporarily open via Defender JIT — or a permanent NSG rule for your laptop IP
- Azure CLI installed locally (or use Cloud Shell)

### Steps

#### 1. Request JIT access (if port 22 isn't already open)

Portal → supabase-vm → Connect → "Request access" (Defender JIT opens 22 for 3 hours from your IP).

#### 2. Tunnel via az ssh

From your laptop (PowerShell / Terminal) or Cloud Shell:

```bash
az ssh vm \
  --resource-group supabase-rg \
  --vm-name supabase-vm \
  --subscription <subscription-id> \
  -- -L 3000:localhost:3000 -L 8000:localhost:8000
```

You'll land in a shell on the VM. Keep this window open.

#### 3. Open Studio

In your browser: **http://localhost:3000**

You'll see the Supabase Studio dashboard. Login if prompted with:
- Username: `supabase`
- Password: stored in Key Vault as `SUPABASE-DASHBOARD-PW`

#### 4. (Optional) Tunnel Postgres too

```bash
az ssh vm \
  --resource-group supabase-rg \
  --vm-name supabase-vm \
  -- -L 5432:localhost:5432
```

Now point psql/pgAdmin/DBeaver at `localhost:5432`:
- Host: `localhost`
- Port: `5432`
- Database: `postgres`
- User: `supabase_admin`
- Password: stored in Key Vault as `SUPABASE-DB-PASSWORD`

#### 5. End the session

Type `exit` in the SSH window or just close it. The tunnel closes; the JIT rule auto-expires.

---

## C. Working with the Database

### Schema design

The recommended pattern is **schema-per-app**:

```sql
-- Each app team owns its own schema
CREATE SCHEMA app_customer_a;
CREATE SCHEMA app_customer_b;
```

This way:
- App 1 can't accidentally read App 2's tables
- Per-schema RLS policies stay manageable
- Schema can be granted to specific roles for cross-app reads when needed

### Row Level Security (RLS)

**Every** table that an app role (`anon`, `authenticated`) can reach **MUST** have RLS enabled. Without RLS, the anon key has read/write access to everything in the schema.

```sql
-- Always enable RLS when creating tables
CREATE TABLE app_customer_a.posts (
  id         uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id    uuid NOT NULL REFERENCES auth.users(id),
  body       text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE app_customer_a.posts ENABLE ROW LEVEL SECURITY;

-- Policy: users can only see/edit their own rows
CREATE POLICY "users own their posts" ON app_customer_a.posts
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
```

### Migrations

For now, schema changes go in your app's repo as `.sql` files. The CI pipeline runs them against Supabase using the service-role key. Format suggestion:

```
app_repo/
└── db/
    └── migrations/
        ├── 0001_create_posts.sql
        ├── 0002_add_index.sql
        └── ...
```

If you're wiring this into a CI/CD pipeline, standardize this step in your shared pipeline templates rather than duplicating it per app — see [WIRING-AN-APP-TO-SUPABASE.md](./WIRING-AN-APP-TO-SUPABASE.md) for the per-app pattern.

---

## 🔧 Troubleshooting

### App can't reach Supabase (timeout, "connection refused")

- Confirm VNet integration is enabled on the App Service
- Confirm subnet is `snet-appservice` (10.50.32.0/22)
- Test from the App Service Console (SCM):
  ```
  curl http://10.50.10.4:8000/auth/v1/health
  ```
  Should return `{"version":"vunspecified"}` or similar JSON

### "JWT expired" or "invalid signature" errors

- The anon/service keys must be signed with the same JWT secret currently in `SUPABASE-JWT-SECRET`
- If you rotated the JWT secret, you must regenerate the keys; the old ones are now invalid

### RLS blocking legitimate reads

- Verify policies: `SELECT * FROM pg_policies WHERE tablename = '...';`
- Confirm the user's role: `SELECT auth.role(), auth.uid();` (inside a query)

### Studio shows "Failed to connect"

- The SSH tunnel might have dropped — reopen it
- Check Studio container is healthy: `docker compose ps studio`

### Realtime subscriptions don't fire

- Confirm the table is in the publication:
  ```sql
  SELECT * FROM pg_publication_tables WHERE pubname = 'supabase_realtime';
  ```
- Add it: `SELECT realtime.enable_table('public', 'your_table');`

---

## 📞 Need help?

- The platform owner (whoever provisioned the VM) owns the VM, secrets, backups, and upgrades
- App teams own their schemas, RLS policies, and migrations
- For anything in-between, use whatever internal support channel your organization uses for infra questions
