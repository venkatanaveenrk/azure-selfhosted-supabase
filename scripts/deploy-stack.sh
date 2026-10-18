#!/usr/bin/env bash
# ================================================================
# deploy-stack.sh — Deploy / update the Supabase stack on the VM (v3)
# ================================================================
# Run this ON THE VM. It:
#   1. Pulls/creates secrets in Key Vault (JWT, DB, service-role pws)
#   2. Generates the .env file from .env.template
#   3. Renders the bootstrap 02 SQL template into the bootstrap dir,
#      substituting :'placeholder' vars with the resolved passwords
#   4. Pulls images and starts the Docker Compose stack
#
# Safe to re-run — it recreates .env and restarts containers. The
# database and storage data are untouched (they live in Docker named
# volumes whose physical storage is on the managed data disk).
#
# Layout (created by cloud-init):
#   /opt/supabase/
#     compose/      docker-compose.yml + .env + kong.yml
#     bootstrap/    SQL scripts (mounted into the DB container)
#     scripts/      this script + backups/restore
#
# Prerequisites on the VM:
#   - Docker + Compose (installed by cloud-init)
#   - az CLI logged in (system managed identity reads Key Vault)
#   - Data disk mounted at /mnt/supabase-data
#
# Env vars this script reads:
#   KEY_VAULT_NAME   Key Vault to pull/create secrets in (default: supabase-kv)
#   CUSTOMER_NAME    Shown as the Studio org name (default: "My Organization")
#
# Example:
#   KEY_VAULT_NAME=contoso-supabase-kv CUSTOMER_NAME="contoso" ./deploy-stack.sh
# ================================================================
set -euo pipefail

KEY_VAULT="${KEY_VAULT_NAME:-supabase-kv}"
CUSTOMER_NAME="${CUSTOMER_NAME:-My Organization}"
# STACK_DIR points at the compose subdir (where docker-compose.yml lives).
# This script also touches the parent /opt/supabase/bootstrap, but `docker compose`
# itself MUST run with cwd == compose/.
STACK_DIR="${STACK_DIR:-/opt/supabase/compose}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/opt/supabase/bootstrap}"
DATA_DIR="${DATA_DIR:-/mnt/supabase-data}"

echo "═══════════════════════════════════════════════"
echo "  Supabase Stack Deploy (v3)"
echo "═══════════════════════════════════════════════"
echo "  Key Vault : $KEY_VAULT"
echo "  Stack dir : $STACK_DIR"
echo "  Bootstrap : $BOOTSTRAP_DIR"
echo "  Data dir  : $DATA_DIR"
echo "═══════════════════════════════════════════════"

# ─── Pre-flight checks ───
[ -d "$DATA_DIR" ]        || { echo "❌ Data disk not mounted at $DATA_DIR"; exit 1; }
[ -d "$STACK_DIR" ]       || { echo "❌ Stack dir not found: $STACK_DIR"; exit 1; }
[ -d "$BOOTSTRAP_DIR" ]   || { echo "❌ Bootstrap dir not found: $BOOTSTRAP_DIR"; exit 1; }
command -v docker >/dev/null || { echo "❌ Docker not installed"; exit 1; }

cd "$STACK_DIR"

# ─── Helper: fetch / create a secret in Key Vault ───
kv() {
  az keyvault secret show --vault-name "$KEY_VAULT" --name "$1" --query value -o tsv
}

get_or_create_secret() {
  local name="$1"
  if az keyvault secret show --vault-name "$KEY_VAULT" --name "$name" >/dev/null 2>&1; then
    kv "$name"
  else
    local val
    val="$(openssl rand -hex 24)"
    az keyvault secret set --vault-name "$KEY_VAULT" --name "$name" --value "$val" --output none
    echo "$val"
  fi
}

echo
echo "→ Fetching base secrets from Key Vault..."
JWT_SECRET="$(kv SUPABASE-JWT-SECRET)"
ANON_KEY="$(kv SUPABASE-ANON-KEY)"
SERVICE_KEY="$(kv SUPABASE-SERVICE-KEY)"
POSTGRES_PASSWORD="$(kv SUPABASE-DB-PASSWORD)"
echo "  ✓ base secrets retrieved"

echo "→ Resolving service passwords (creating in KV if absent)..."
AUTHENTICATOR_PASSWORD="$(get_or_create_secret SUPABASE-AUTHENTICATOR-PW)"
AUTH_ADMIN_PASSWORD="$(get_or_create_secret SUPABASE-AUTH-ADMIN-PW)"
STORAGE_ADMIN_PASSWORD="$(get_or_create_secret SUPABASE-STORAGE-ADMIN-PW)"
REALTIME_ADMIN_PASSWORD="$(get_or_create_secret SUPABASE-REALTIME-ADMIN-PW)"
REALTIME_SECRET_KEY_BASE="$(get_or_create_secret SUPABASE-REALTIME-KEYBASE)"
DASHBOARD_PASSWORD="$(get_or_create_secret SUPABASE-DASHBOARD-PW)"
echo "  ✓ service passwords resolved"

# ─── VM private IP (for API URLs) ───
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
echo "→ VM private IP: $PRIVATE_IP"

# ─── Generate .env from template ───
echo "→ Generating .env from .env.template..."
cp .env.template .env
sed -i \
  -e "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD}|g" \
  -e "s|REPLACE_AUTHENTICATOR_PASSWORD|${AUTHENTICATOR_PASSWORD}|g" \
  -e "s|REPLACE_AUTH_ADMIN_PASSWORD|${AUTH_ADMIN_PASSWORD}|g" \
  -e "s|REPLACE_STORAGE_ADMIN_PASSWORD|${STORAGE_ADMIN_PASSWORD}|g" \
  -e "s|REPLACE_JWT_SECRET|${JWT_SECRET}|g" \
  -e "s|REPLACE_ANON_KEY|${ANON_KEY}|g" \
  -e "s|REPLACE_SERVICE_ROLE_KEY|${SERVICE_KEY}|g" \
  -e "s|REPLACE_VM_PRIVATE_IP|${PRIVATE_IP}|g" \
  -e "s|REPLACE_DASHBOARD_PASSWORD|${DASHBOARD_PASSWORD}|g" \
  -e "s|REPLACE_REALTIME_SECRET_KEY_BASE|${REALTIME_SECRET_KEY_BASE}|g" \
  -e "s|REPLACE_CUSTOMER_NAME|${CUSTOMER_NAME}|g" \
  .env
chmod 600 .env
echo "  ✓ .env generated (mode 600)"

# ─── Render bootstrap 02 with concrete passwords ───
# Postgres' /docker-entrypoint-initdb.d runs *.sql files in alpha order
# but does NOT support psql -v flags. So we render a concrete copy from
# the template each deploy. The rendered file is what gets mounted into
# the db container (compose mounts ./bootstrap as a symlink to
# /opt/supabase/bootstrap).
#
# We write the rendered file alongside the
# template, not over it. This keeps the repo state clean across re-runs.
echo "→ Rendering bootstrap 02 with passwords..."
RENDERED="$BOOTSTRAP_DIR/02-service-passwords.sql"
sed \
  -e "s|:'postgres_pw'|'${POSTGRES_PASSWORD}'|g" \
  -e "s|:'authenticator_pw'|'${AUTHENTICATOR_PASSWORD}'|g" \
  -e "s|:'auth_admin_pw'|'${AUTH_ADMIN_PASSWORD}'|g" \
  -e "s|:'storage_admin_pw'|'${STORAGE_ADMIN_PASSWORD}'|g" \
  -e "s|:'realtime_admin_pw'|'${REALTIME_ADMIN_PASSWORD}'|g" \
  "$BOOTSTRAP_DIR/02-service-passwords.sql.template" > "$RENDERED"
chmod 600 "$RENDERED"
echo "  ✓ rendered $RENDERED"

# ─── Ensure compose can find ./bootstrap ───
# docker-compose.yml expects ./bootstrap relative to STACK_DIR. We
# symlink it to the central bootstrap dir so compose mounts the
# right files.
if [ ! -e "$STACK_DIR/bootstrap" ]; then
  ln -s "$BOOTSTRAP_DIR" "$STACK_DIR/bootstrap"
  echo "  ✓ symlinked $STACK_DIR/bootstrap -> $BOOTSTRAP_DIR"
fi

# ─── Pull images + start ───
echo
echo "→ Pulling images (this can take a few minutes)..."
docker compose pull

echo "→ Starting the stack..."
docker compose up -d

echo
echo "→ Waiting 30s for services to settle..."
sleep 30
docker compose ps

echo
echo "═══════════════════════════════════════════════"
echo "  ✅ Supabase stack deployed"
echo "═══════════════════════════════════════════════"
echo "  API (Kong):    http://${PRIVATE_IP}:8000"
echo "  Studio:        http://127.0.0.1:3000  (basic-auth, SSH tunnel only)"
echo
echo "  Verify Auth:   curl http://${PRIVATE_IP}:8000/auth/v1/health"
echo "  Verify REST:   curl -H \"apikey: \$ANON_KEY\" http://${PRIVATE_IP}:8000/rest/v1/"
echo "═══════════════════════════════════════════════"
