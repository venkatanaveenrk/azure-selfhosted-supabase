# 🟢 self-hosted-supabase — Self-Hosted Supabase on Azure

Self-hosted Supabase on a single Azure VM (Docker Compose), private VNet, with **App Service VNet integration** as the primary access path for apps. A reusable, generic template — deploy it for any client or project by setting `customer_name`.

> **Why a VM, not Azure Database for PostgreSQL?**
> Supabase needs PostgreSQL **superuser**, the **`pgjwt`** extension, and **`BYPASSRLS`** — none of which Azure's managed PostgreSQL service allows. Supabase must run on infrastructure you fully control.

### Built to be reused, not one-off

Nothing in this repo is hardcoded to a specific company or project. Clone it, set seven values (`customer_name`, resource group, Key Vault, VM name, VNet CIDR, admin username, region), and deploy. Running it again for a different client — or a second isolated environment for the same client — is the same procedure with a different `terraform.tfvars`. See the identity table in [DEPLOY.md](./DEPLOY.md).

---

## 📐 Architecture

```
   ┌──────────────────────────────────────────────────────────┐
   │  supabase-rg                                        │
   │                                                          │
   │  ┌─────────────────────────────────────────────────┐    │
   │  │  supabase-vnet (10.50.0.0/16)                │    │
   │  │                                                  │    │
   │  │  GatewaySubnet  (10.50.0.0/27)                   │    │
   │  │   └── VPN Gateway VpnGw2AZ (DISABLED by default) │    │
   │  │                                                  │    │
   │  │  snet-supabase  (10.50.10.0/24)                  │    │
   │  │   └── supabase-vm                            │    │
   │  │       Ubuntu 24.04, D2s_v3, Trusted Launch       │    │
   │  │       System-assigned managed identity           │    │
   │  │       + 128 GB Premium SSD data disk             │    │
   │  │         (prevent_destroy, Docker named volumes)  │    │
   │  │                                                  │    │
   │  │  snet-appservice (10.50.32.0/22, delegated)      │    │
   │  │   └── App Services VNet-integrate here           │    │
   │  │       and talk to Supabase via private IP        │    │
   │  └─────────────────────────────────────────────────┘    │
   │                                                          │
   │  Reuses an existing Key Vault (var.key_vault_name) for all secrets │
   └──────────────────────────────────────────────────────────┘
```

**Key design properties:**
- VM has **no public IP** by default — VNet-only access
- App Services reach Supabase **privately over the VNet** (App Service VNet integration)
- All persistent data on a **separate managed disk** that survives any VM event
- Docker's **data-root** is set to the data disk so named volumes persist there
- VM authenticates to Key Vault via **managed identity** — no stored credentials
- VPN Gateway is **opt-in** (saves ~$365/mo when off, which is the default)
- Monitoring/Log Analytics is **opt-in** (saves ~$5/mo)

---

## 📁 Repo Layout

```
self-hosted-supabase/
├── terraform/                       Infrastructure as Code
│   ├── versions.tf
│   ├── variables.tf                 All deployment knobs
│   ├── terraform.tfvars.example     Copy → terraform.tfvars, edit, apply
│   ├── network.tf                   VNet, 3 subnets, NSG
│   ├── vpn.tf                       VPN Gateway (off by default)
│   ├── vm.tf                        VM + data disk + MI + KV role
│   ├── monitoring.tf                Log Analytics + alerts (off by default)
│   ├── cloud-init.yaml              Docker (with data-root on data disk),
│   │                                disk mount, autostart, hardening
│   └── outputs.tf
├── compose/                         The Supabase stack
│   ├── docker-compose.yml           9 services, named volumes
│   ├── kong.yml                     API gateway routing
│   └── .env.template
├── bootstrap/                       Database init scripts
│   ├── README.md
│   ├── 01-roles-and-schemas.sql              Roles, schemas, helpers
│   ├── 02-service-passwords.sql.template     Template (rendered by deploy)
│   └── 03-realtime-setup.sql                 Realtime publication
├── scripts/
│   ├── generate-jwt-keys.sh         Bootstrap the 4 required Key Vault secrets
│   ├── deploy-stack.sh              Pulls secrets, renders, starts stack
│   ├── backup.sh                    pg_dump + disk snapshot
│   ├── restore.sh                   restore from a dump
│   └── verify-persistence.sh        PROVES data survives restarts
├── DEPLOY.md                        Step-by-step deployment runbook
├── DEVELOPER-ACCESS.md              Hand this to your dev team
├── WIRING-AN-APP-TO-SUPABASE.md     Hand this to app teams
└── README.md                        You are here
```

---

## ✅ Prerequisites

Before you start, make sure you have:

- **Azure access**: an account with **Owner** or **User Access Administrator** on the target subscription/resource group — plain Contributor is not enough, because this stack creates role assignments (Key Vault RBAC + the VM's managed identity)
- **Terraform ≥ 1.6** ([install](https://developer.hashicorp.com/terraform/install)) — Azure Cloud Shell already has it
- **Azure CLI**, logged in (`az login`)
- **Python 3** with `PyJWT` — used once to mint the anon/service-role JWTs; `scripts/generate-jwt-keys.sh` installs it automatically if missing
- **An existing Azure resource group and Key Vault** for the instance — this module reuses them rather than creating them (see DEPLOY.md Step 1–2 if you need to create one)
- **A Terraform state backend** (an Azure Storage account + container) — either reuse an existing one or create one (DEPLOY.md Step 0, one-time per organization)
- **VM quota** for your chosen `vm_size` (default `Standard_D2s_v3`) in your target region — new/free-tier subscriptions sometimes start at 0 and need a quota increase
- These resource providers registered on the subscription: `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.KeyVault`, `Microsoft.Storage` (and `Microsoft.OperationalInsights` if you'll enable monitoring)

Full detail and exact commands for each of these: **[DEPLOY.md](./DEPLOY.md)** (§ Prerequisites).

---

## 🔑 What You Need To Fill In

Nothing in this repo is hardcoded to a company or project — you provide these values per deployment:

| Value | Where | Notes |
|---|---|---|
| `customer_name` | `terraform.tfvars` | Free text — drives tags + Studio branding only |
| `resource_group` | `terraform.tfvars` | Must already exist |
| `key_vault_name` | `terraform.tfvars` | Must already exist, with the 4 bootstrap secrets populated (below) |
| `vnet_name`, `vm_name` | `terraform.tfvars` | Suggested pattern: `<customer>-supabase-*` |
| `vnet_address_space` + 3 subnet CIDRs | `terraform.tfvars` | Must not overlap any VNet you might ever peer with |
| `admin_username` | `terraform.tfvars` | Not on Azure's reserved list (`admin`, `root`, `user`, `test`, etc.) |
| Terraform state backend (`resource_group_name`, `storage_account_name`, `container_name`, `key`) | `terraform init -backend-config=...` flags | `key` must be unique per deployment |
| 4 bootstrap Key Vault secrets | Created by `scripts/generate-jwt-keys.sh <key-vault-name>` before `terraform apply` | JWT secret, DB password, anon key, service-role key |

Copy `terraform/terraform.tfvars.example` → `terraform/terraform.tfvars` and fill in the values above — that's the only file you need to edit for a new deployment. The full walkthrough, with copy-pasteable commands for each step, is in **[DEPLOY.md](./DEPLOY.md)**.

---

## 🚀 Deploying

The full deployment runbook lives in **[DEPLOY.md](./DEPLOY.md)**. In brief:

1. Create a resource group + Key Vault for this Supabase instance
2. Run `scripts/generate-jwt-keys.sh <key-vault-name>` — creates the four bootstrap secrets (JWT secret, DB password, anon key, service-role key)
3. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars` and edit values (including `customer_name`)
4. `terraform init` (with the right backend state key) + `terraform apply`
5. Upload `compose/`, `bootstrap/`, `scripts/` to the VM and run `deploy-stack.sh`
6. Verify with the health checks in DEPLOY.md § Step 8

About 20-30 minutes end-to-end. Repeat the same procedure for each new client — what changes between clients is just the contents of `terraform.tfvars`.

---


## 🔌 Connecting Your Apps

This part is **per-app, done manually**:

1. App Service → your app → **Networking** → **VNet integration** → connect to `supabase-vnet` / `snet-appservice`
2. In the app's `apps.json`, add the Supabase env vars + secret mappings (see [WIRING-AN-APP-TO-SUPABASE.md](./WIRING-AN-APP-TO-SUPABASE.md))
3. Push — pipeline deploys with the new config

That's it. Apps now reach Supabase privately, with no internet exposure.

---

## 💾 Data Persistence — The Guarantee

| Event | Data survives? |
|---|---|
| Container restart | ✅ Data in Docker named volumes, not the container |
| `docker compose down && up -d` | ✅ Named volumes persist |
| Stack redeploy via systemd | ✅ Same |
| VM reboot | ✅ Disk re-mounts via fstab; named volumes intact |
| VM resize (`vm_size` change + apply) | ✅ Disk detaches/reattaches |
| VM deletion and recreation | ✅ `prevent_destroy` keeps the disk; reattach manually |
| `docker compose down -v` (explicit) | ❌ `-v` flag deletes volumes — DON'T |
| Data disk deletion | ❌ Only real risk — guarded by `prevent_destroy` + daily snapshots |

**Prove it:**

```bash
./scripts/verify-persistence.sh write       # writes markers
sudo systemctl restart supabase             # or: docker compose down && up -d
./scripts/verify-persistence.sh check       # confirms markers survived
```

---

## 💾 Backups

Daily via cron on the VM:

```bash
sudo tee /etc/cron.d/supabase-backup > /dev/null <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root RESOURCE_GROUP=supabase-rg DATA_DISK_NAME=supabase-vm-data-disk /opt/supabase/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
CRON
sudo systemctl restart cron
```

- pg_dump → `/mnt/supabase-data/backups/`
- Azure managed-disk snapshot → stored in Azure
- 14-day retention (configurable via `RETENTION_DAYS`)

---

## 🆘 Disaster Recovery

### Restore from a dump

```bash
./scripts/restore.sh /mnt/supabase-data/backups/supabase-db-YYYYMMDD-HHMMSS.sql.gz
```

### Recover the disk from a snapshot

```bash
az disk create --resource-group supabase-rg \
  --name supabase-vm-data-disk-restored \
  --source <snapshot-name>
```

Then detach the old disk, attach the restored one, and reboot the VM.

### Total VM loss

The data disk has `prevent_destroy` and lives independently. `terraform apply` to rebuild the VM; reattach the existing disk (LUN 0).

---

## ⬆️ Upgrading Supabase

1. Back up: `./scripts/backup.sh`
2. Edit `compose/docker-compose.yml` — update image tags **as a set** (Supabase versions tested together)
3. On the VM: `cd /opt/supabase/compose && docker compose pull && docker compose up -d`

Brief blip (seconds) per service during the swap.

---

## 🔧 Common Operations

```bash
# Status
docker compose ps
sudo systemctl status supabase

# Logs
docker compose logs -f auth
docker compose logs --tail=200 db

# Restart one service
docker compose restart realtime

# Connect to the DB
docker exec -it supabase-db psql -U supabase_admin -d postgres

# Stop / start the whole stack
sudo systemctl stop supabase
sudo systemctl start supabase
```

---

## 🌐 Accessing Studio (admin dashboard)

Studio is published only on the VM's loopback (`127.0.0.1:3000`) for security. To reach it from your laptop:

```bash
# From Cloud Shell or your laptop (Azure AD-based, no SSH key needed):
az ssh vm --resource-group supabase-rg --vm-name supabase-vm \
  -- -L 3000:localhost:3000 -L 8000:localhost:8000
```

Then in your browser: **http://localhost:3000**

Note: this requires the VM to have a public IP attached and the SSH port temporarily open (use [Defender JIT](https://learn.microsoft.com/en-us/azure/defender-for-cloud/just-in-time-access-usage) for ~3-hour windows).

---

## 🔻 Enabling the VPN (if needed later)

```hcl
# In terraform/variables.tf
variable "enable_vpn_gateway" {
  default = true
}
```

```bash
terraform apply   # provisions VPN Gateway + public IP (~30 min, ~$365/mo)
```

---

## ⚠️ Known Limitations

- **Single VM** — VM down = Supabase down. Data stays safe. HA needs multi-VM/AKS (future).
- **D2s_v3 is the floor** — resize via `vm_size` when load grows; disk persists.
- **No SMTP yet** — auth signups are auto-confirmed; add SMTP later via GoTrue env vars.
- **HTTP internally** — fine over private VNet; TLS via App Gateway / Nginx only if exposed publicly.
- **No migration pipeline yet** — schema changes via Studio/psql for now.

---

## 📋 Key Vault Secrets

| Secret | Purpose |
|---|---|
| `SUPABASE-JWT-SECRET` | Shared JWT signing secret |
| `SUPABASE-ANON-KEY` | Public API key (safe in client code) |
| `SUPABASE-SERVICE-KEY` | Backend god-mode key (NEVER expose to client) |
| `SUPABASE-DB-PASSWORD` | supabase_admin password |
| `SUPABASE-AUTHENTICATOR-PW` | PostgREST role password |
| `SUPABASE-AUTH-ADMIN-PW` | GoTrue role password |
| `SUPABASE-STORAGE-ADMIN-PW` | Storage role password |
| `SUPABASE-REALTIME-ADMIN-PW` | Realtime role password |
| `SUPABASE-REALTIME-KEYBASE` | Realtime SECRET_KEY_BASE |
| `SUPABASE-DASHBOARD-PW` | Studio basic-auth password |
| `SUPABASE-VM-ADMIN-SSH-KEY` | Break-glass SSH key for the VM |

---

## 💰 Cost Snapshot

| Item | Monthly |
|---|---|
| VM (D2s_v3) | ~$87 |
| OS disk (Premium SSD 30 GB) | ~$3 |
| Data disk (Premium SSD 128 GB) | ~$19 |
| Snapshots, bandwidth | ~$5–10 |
| **Total (default config: no VPN, no monitoring)** | **~$114** |
| Log Analytics + alerts (opt-in) | +~$5 |
| VPN Gateway VpnGw2AZ (opt-in) | +~$365 |

---

## 📞 More Docs

- **[DEPLOY.md](./DEPLOY.md)** — full deployment runbook
- **[DEVELOPER-ACCESS.md](./DEVELOPER-ACCESS.md)** — share with developers
- **[WIRING-AN-APP-TO-SUPABASE.md](./WIRING-AN-APP-TO-SUPABASE.md)** — share with app teams

---

## License

MIT — see [LICENSE](./LICENSE). Use it, fork it, adapt it for your own clients.

---

*A reusable Terraform + Docker Compose template for self-hosting Supabase on Azure, with private VNet networking, persistent data disks, and App Service integration. Built and hardened through real deployment cycles — see [DEPLOY.md](./DEPLOY.md) for the full runbook.*
