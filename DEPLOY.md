# 🚀 Deploying self-hosted-supabase

This is the canonical procedure for spinning up a production Supabase instance from this repo for a client. The same procedure works for every client — only what you put in `terraform.tfvars` changes.

> **Estimated time:** ~20-30 minutes hands-on.

---

## 📋 Before You Start — Pick The Identity

Decide these values up-front. **`contoso` in the Example column is a sample placeholder — swap in your actual client/company name everywhere it appears before you deploy.**

| What | Example |
|---|---|
| **customer_name** | `contoso` |
| **Resource group** | `contoso-supabase-rg` |
| **Key Vault** | `contoso-supabase-kv` |
| **VM name** | `contoso-supabase-vm` |
| **VNet CIDR** | `10.50.0.0/16` |
| **TF state key** | `contoso/supabase-vm/terraform.tfstate` |
| **Admin username** | (your choice, not on Azure's reserved list) |

`customer_name` is free text — it drives resource **tags** and Studio branding only, not Azure resource names (those must follow Azure's naming rules, so set them explicitly as shown above). This is what makes the template reusable: clone the repo, set these seven values for the client, deploy — no code changes needed per client.

**Rule of thumb:** each client gets its own resource group, its own Key Vault, and its own non-overlapping VNet CIDR. The Terraform state storage account can be shared across clients (only the state-file `key` differs per deployment).

The `terraform.tfvars.example` file in `terraform/` has a working set of values you can copy and adjust.

---

## ✅ Prerequisites

- Azure CLI logged in to a user with **Owner** or **User Access Administrator** on the subscription (or at least on the target resource group) — plain **Contributor is NOT enough**, because Step 2 and the Terraform apply both create role assignments (`az role assignment create` / `azurerm_role_assignment`), and only Owner/User Access Administrator can grant roles to other identities
- Terraform ≥ 1.6 available (Cloud Shell has it; otherwise `brew install terraform` / `winget install terraform`)
- Python 3 with `PyJWT` (used once to generate the anon/service-role JWTs — `scripts/generate-jwt-keys.sh` installs it automatically if missing)
- A clone of this repo
- A Terraform state storage account already exists, OR you create one in Step 0 below (first deployment only)
- These resource providers registered on the subscription (usually already are; check with `az provider show --namespace <name> --query registrationState`): `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.KeyVault`, `Microsoft.Storage`, and `Microsoft.OperationalInsights` if you plan to enable monitoring. Register any that show `NotRegistered` with `az provider register --namespace <name>` (takes a few minutes).
- VM quota for the `Standard_D2s_v3` family (or whatever `vm_size` you choose) in your target region — check with `az vm list-usage --location <region> -o table`. New/free-tier subscriptions sometimes start at 0 quota and need a quota increase request first.

---

## ☑️ Pre-Flight Checklist

Verify every item before running `terraform apply`. Most deployment failures trace back to one of these:

- [ ] I have Owner or User Access Administrator on the subscription/RG (not just Contributor)
- [ ] The target region has quota for my chosen `vm_size` (checked via `az vm list-usage`)
- [ ] Required resource providers are registered (Compute, Network, KeyVault, Storage)
- [ ] The Terraform state storage account exists (Step 0) and I have its exact name/RG/container
- [ ] The target resource group already exists (Step 1) — this module does NOT create it
- [ ] The target Key Vault already exists (Step 2) and I have Get/List/Set access to it
- [ ] The 4 bootstrap secrets are populated in that Key Vault (Step 3 / `generate-jwt-keys.sh`)
- [ ] `customer_name` and all naming variables in `terraform.tfvars` are filled in — no `REPLACE_*` placeholders left
- [ ] `admin_username` is set and not on Azure's reserved list
- [ ] My chosen VNet CIDR does not overlap any VNet I might ever peer with
- [ ] I know which Terraform state `key` this deployment uses, and it's unique (no collision with another instance)

---

## Step 0 — One-time: create the Terraform state storage account

**Skip this step if a state storage account already exists for your organization** (check with your team first — it's meant to be shared across deployments, only the state-file `key` differs per instance).

```bash
STATE_RG=tfstate-rg
STATE_ACCOUNT=tfstateaccount     # must be globally unique — adjust if taken
STATE_CONTAINER=tfstate

az group create --name "$STATE_RG" --location eastus

az storage account create \
  --name "$STATE_ACCOUNT" \
  --resource-group "$STATE_RG" \
  --sku Standard_LRS \
  --encryption-services blob \
  --min-tls-version TLS1_2

az storage container create \
  --name "$STATE_CONTAINER" \
  --account-name "$STATE_ACCOUNT" \
  --auth-mode login
```

This is the only resource in the whole setup that Terraform doesn't manage itself (state has to live somewhere before Terraform can track anything) — a one-time manual bootstrap, same reasoning as any Terraform-managed environment. Do this once per organization, not once per client deployment.

---

## Step 1 — Create the resource group

```bash
RG=supabase-vm-rg            # adjust for your deployment

az group create \
  --name "$RG" \
  --location northeurope \
  --tags component=supabase owner=$(az account show --query user.name -o tsv)
```

---

## Step 2 — Create the Key Vault

The Supabase instance needs its own Key Vault. The VM's managed identity will read secrets from here at runtime.

```bash
KV=supabase-kv               # adjust for your deployment

az keyvault create \
  --name "$KV" \
  --resource-group "$RG" \
  --location northeurope \
  --enable-rbac-authorization true \
  --output table

# Grant yourself permission to manage secrets (RBAC mode)
ME=$(az ad signed-in-user show --query id -o tsv)
KV_ID=$(az keyvault show --name "$KV" --query id -o tsv)

az role assignment create \
  --assignee "$ME" \
  --role "Key Vault Administrator" \
  --scope "$KV_ID" \
  --output none

# Wait for the RBAC assignment to propagate
echo "Waiting 30s for RBAC propagation..."; sleep 30
```

---

## Step 3 — Populate the bootstrap secrets

Four secrets must exist before Terraform runs. The remaining per-service passwords (authenticator, auth-admin, storage-admin, realtime-admin, realtime-keybase, dashboard) are created automatically by `deploy-stack.sh` on its first run.

One script does all four — requires `python3` with `PyJWT` (installed automatically if missing):

```bash
chmod +x scripts/generate-jwt-keys.sh
./scripts/generate-jwt-keys.sh "$KV"
```

You should see four secrets confirmed at the end:
```
SUPABASE-ANON-KEY
SUPABASE-DB-PASSWORD
SUPABASE-JWT-SECRET
SUPABASE-SERVICE-KEY
```

> ⚠️ **Each instance needs a unique JWT secret.** Reusing a JWT secret between two instances means a leaked anon key from one could authenticate against the other. The script generates a fresh random secret every time it creates one, and — by default — never overwrites a secret that already exists in the target vault (pass `--force` only if you intend to rotate and invalidate all previously issued tokens).

---

## Step 4 — Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set resource_group, key_vault_name, vm_name,
# vnet ranges, admin_username, etc. to match what you decided above.
```

`admin_username` cannot be in Azure's reserved list (NOT `admin`, `root`, `user`, `test`, etc.) — variable validation will reject reserved names.

The VNet CIDR (default in the example: `10.51.0.0/16`) must not overlap any other VNet you might ever want to peer with.

---

## Step 5 — Apply Terraform

You'll reuse a Terraform state storage account (typically `tfstateaccount`). Only the state-file key differs per deployment.

```bash
terraform init \
  -backend-config="resource_group_name=supabase-rg" \
  -backend-config="storage_account_name=tfstateaccount" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=supabase-vm/terraform.tfstate" \
  -reconfigure

terraform plan -out=tfplan
terraform apply tfplan
```

About 5 minutes (VPN is off by default; with it, ~30 min).

Capture the outputs:

```bash
terraform output
# Note: vm_private_ip (typically 10.51.10.4 if you used the example VNet)
```

---

## Step 6 — Upload the stack to the VM

The VM has no public IP by default. We upload the compose/bootstrap/scripts directories via a SAS-signed blob, then have the VM pull it via `az vm run-command`.

```bash
cd ..   # back to repo root

# Pick values to match this deployment
RG=supabase-vm-rg
VM=supabase-vm
ADMIN_USER=opsuser            # whatever you set in terraform.tfvars

STORAGE=tfstateaccount
CONTAINER=supabase-stack-upload
EXPIRY=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%MZ)

az storage container create \
  --account-name "$STORAGE" --name "$CONTAINER" --auth-mode login --output none

tar czf /tmp/stack.tgz compose bootstrap scripts

az storage blob upload \
  --account-name "$STORAGE" --container-name "$CONTAINER" \
  --name stack.tgz --file /tmp/stack.tgz \
  --auth-mode login --overwrite --output none

SAS=$(az storage blob generate-sas \
  --account-name "$STORAGE" --container-name "$CONTAINER" \
  --name stack.tgz --permissions r --expiry "$EXPIRY" \
  --auth-mode login --as-user -o tsv)

URL="https://$STORAGE.blob.core.windows.net/$CONTAINER/stack.tgz?$SAS"

az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "
    set -e
    curl -sSL '$URL' | tar xz -C /opt/supabase
    chown -R $ADMIN_USER:$ADMIN_USER /opt/supabase
    chmod +x /opt/supabase/scripts/*.sh
    ls -la /opt/supabase/
  "
```

The output should show `compose/`, `bootstrap/`, `scripts/` populated under `/opt/supabase`.

---

## Step 7 — Run deploy-stack.sh

Point it at the right Key Vault via `KEY_VAULT_NAME`, and set `CUSTOMER_NAME` to brand the Studio dashboard:

```bash
KV=supabase-kv               # whatever you used in Step 2
CUSTOMER="contoso"         # shown as the org name inside Studio

az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "KEY_VAULT_NAME=$KV CUSTOMER_NAME='$CUSTOMER' /opt/supabase/scripts/deploy-stack.sh"
```

This will:
1. Pull (or create) the per-service passwords in the Key Vault
2. Render `.env` and `bootstrap/02-service-passwords.sql`
3. `docker compose pull && docker compose up -d`
4. Print health status

**Expected duration:** 3-5 minutes (most of it is image pulls on the first run).

---

## Step 8 — Verify

All 9 services should come up healthy. Run:

```bash
az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "
cd /opt/supabase/compose

echo '════════ SERVICES ════════'
docker compose ps

echo
echo '════════ AUTH HEALTH ════════'
curl -s http://localhost:8000/auth/v1/health
echo

echo
echo '════════ REST HEALTH ════════'
ANON=\$(az keyvault secret show --vault-name $KV --name SUPABASE-ANON-KEY --query value -o tsv)
curl -s -H \"apikey: \$ANON\" http://localhost:8000/rest/v1/
echo

echo
echo '════════ SIGNUP TEST ════════'
curl -s -X POST http://localhost:8000/auth/v1/signup \
  -H 'Content-Type: application/json' \
  -H \"apikey: \$ANON\" \
  -d '{\"email\": \"validate@example.com\", \"password\": \"TestValidate2026!\"}'
echo

echo
echo '════════ PERSISTENCE TEST (WRITE) ════════'
/opt/supabase/scripts/verify-persistence.sh write

echo
echo '════════ RESTART (down + up) ════════'
docker compose down
docker compose up -d
sleep 30
docker compose ps

echo
echo '════════ PERSISTENCE TEST (CHECK) ════════'
/opt/supabase/scripts/verify-persistence.sh check
"
```

### What "PASS" looks like

The output ends with:

```
═══════════════════════════════════════════════
  ✅ PASS — data persisted across the restart
═══════════════════════════════════════════════
```

And `docker compose ps` shows 9 services with **Up** status. Some may be marked "unhealthy" cosmetically — that's the compose healthcheck reporter being conservative; if the persistence test passes the stack is fine.

### Acceptance criteria

A deployment is considered successful when:

- [x] `terraform apply` completes without error
- [x] All 9 Docker services come up
- [x] Auth signup endpoint returns a JWT
- [x] REST endpoint with anon key returns valid JSON
- [x] `verify-persistence.sh check` says **PASS** after `docker compose down && up -d`
- [x] No manual intervention on the VM was required

---

## 🆘 Troubleshooting

### `terraform apply` fails

Most failures here are about reserved usernames (variable validation), incorrect Key Vault name (must already exist with secrets pre-populated), or a state-key collision (someone else used the same key in the same backend). Read the error carefully — Terraform's messages are usually precise.

### Service won't come up healthy after `deploy-stack.sh`

```bash
# Get logs from the failing service
az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "cd /opt/supabase/compose && docker compose logs --tail=200 <service-name>"
```

The most common cause is a missing or mistyped secret in the Key Vault. Verify all six bootstrap secrets exist with `az keyvault secret list --vault-name "$KV"`.

### Persistence test fails

Check that the data disk is mounted and Docker's data-root points at it:

```bash
az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "df -h /mnt/supabase-data; docker info | grep 'Docker Root Dir'"
```

Expected:
- `/mnt/supabase-data` mounted with ~120GB+ free
- `Docker Root Dir: /mnt/supabase-data/docker`

If either is wrong, cloud-init didn't finish — check `/var/log/cloud-init-output.log` on the VM.

---

## 🧹 Offboarding a Client

If a client engagement ends and the instance needs to be decommissioned:

```bash
# Method 1: Deallocate the VM only (keeps everything for a grace period; ~$1/day for disks)
az vm deallocate --resource-group "$RG" --name "$VM"

# Method 2: Full teardown — delete the whole resource group
# (data disk's prevent_destroy doesn't apply to a direct az group delete,
# so back up first via scripts/backup.sh if the client wants a final export)
az group delete --name "$RG" --yes --no-wait

# Clean up the state file
az storage blob delete \
  --account-name tfstateaccount \
  --container-name tfstate \
  --name "contoso/supabase-vm/terraform.tfstate" \
  --auth-mode login

# Locally
cd terraform
rm -f terraform.tfvars .terraform.lock.hcl
rm -rf .terraform
```

---

## 💰 Cost Reference

Approximate Azure cost per client instance (defaults: no VPN, no monitoring):

| Item | Monthly |
|---|---|
| VM (Standard_D2s_v3) | ~$87 |
| OS disk (Premium SSD 30 GB) | ~$3 |
| Data disk (Premium SSD 128 GB) | ~$19 |
| Misc (NICs, snapshots, bandwidth) | ~$5-10 |
| **Total per client instance** | **~$115-120** |

Smaller data disk (e.g. 32 GB) saves ~$15/mo if a client's data volume is genuinely small — adjust `data_disk_size_gb` in `terraform.tfvars`.

---

*Maintained by whoever owns this deployment — update this line once you fork the repo for your own team.*
