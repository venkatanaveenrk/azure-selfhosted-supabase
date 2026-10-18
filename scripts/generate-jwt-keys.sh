#!/usr/bin/env bash
# ================================================================
# generate-jwt-keys.sh — Bootstrap the 4 secrets Supabase needs
# before its first deploy, and write them to Key Vault.
# ================================================================
# Run this ONCE per deployment, BEFORE `terraform apply` and BEFORE
# scripts/deploy-stack.sh. Safe to re-run — it will not overwrite
# secrets that already exist in the target Key Vault (use --force to
# rotate them, which invalidates all previously-issued tokens).
#
# Creates:
#   SUPABASE-JWT-SECRET     — the shared signing secret
#   SUPABASE-DB-PASSWORD    — Postgres superuser password
#   SUPABASE-ANON-KEY       — long-lived JWT, role=anon
#   SUPABASE-SERVICE-KEY    — long-lived JWT, role=service_role
#
# Requires: az CLI (logged in, Key Vault Administrator or Secrets
# Officer on the target vault), python3, and the PyJWT package.
#
# Usage:
#   ./generate-jwt-keys.sh <key-vault-name> [--force]
#
# Example:
#   ./generate-jwt-keys.sh contoso-supabase-kv
# ================================================================
set -euo pipefail

KEY_VAULT="${1:-}"
FORCE="${2:-}"

if [ -z "$KEY_VAULT" ]; then
  echo "Usage: $0 <key-vault-name> [--force]"
  echo "Example: $0 contoso-supabase-kv"
  exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  Generating Supabase Bootstrap Secrets"
echo "═══════════════════════════════════════════════"
echo "  Key Vault : $KEY_VAULT"
echo "  Force     : ${FORCE:-no}"
echo "═══════════════════════════════════════════════"
echo

command -v az >/dev/null      || { echo "❌ Azure CLI not found"; exit 1; }
command -v python3 >/dev/null || { echo "❌ python3 not found"; exit 1; }
python3 -c "import jwt" 2>/dev/null || {
  echo "→ Installing PyJWT..."
  pip install --quiet --user PyJWT
}

secret_exists() {
  az keyvault secret show --vault-name "$KEY_VAULT" --name "$1" >/dev/null 2>&1
}

set_secret() {
  local name="$1" value="$2"
  az keyvault secret set --vault-name "$KEY_VAULT" --name "$name" --value "$value" --output none
}

# ─── 1. JWT signing secret ───
if secret_exists "SUPABASE-JWT-SECRET" && [ "$FORCE" != "--force" ]; then
  echo "→ SUPABASE-JWT-SECRET already exists, skipping (use --force to rotate)"
  JWT_SECRET="$(az keyvault secret show --vault-name "$KEY_VAULT" --name SUPABASE-JWT-SECRET --query value -o tsv)"
else
  echo "→ Generating SUPABASE-JWT-SECRET..."
  JWT_SECRET="$(openssl rand -hex 32)"
  set_secret "SUPABASE-JWT-SECRET" "$JWT_SECRET"
fi

# ─── 2. Postgres admin password ───
if secret_exists "SUPABASE-DB-PASSWORD" && [ "$FORCE" != "--force" ]; then
  echo "→ SUPABASE-DB-PASSWORD already exists, skipping (use --force to rotate)"
else
  echo "→ Generating SUPABASE-DB-PASSWORD..."
  set_secret "SUPABASE-DB-PASSWORD" "$(openssl rand -base64 24 | tr -d '=+/')"
fi

# ─── 3. Anon JWT (role=anon, 10-year expiry) ───
echo "→ Generating SUPABASE-ANON-KEY..."
ANON_KEY=$(JWT_SECRET="$JWT_SECRET" python3 - <<'PY'
import jwt, time, os
print(jwt.encode({
  'role': 'anon',
  'iss': 'supabase',
  'iat': int(time.time()),
  'exp': int(time.time()) + 10*365*86400
}, os.environ['JWT_SECRET'], algorithm='HS256'))
PY
)
set_secret "SUPABASE-ANON-KEY" "$ANON_KEY"

# ─── 4. Service-role JWT (role=service_role, 10-year expiry) ───
echo "→ Generating SUPABASE-SERVICE-KEY..."
SERVICE_KEY=$(JWT_SECRET="$JWT_SECRET" python3 - <<'PY'
import jwt, time, os
print(jwt.encode({
  'role': 'service_role',
  'iss': 'supabase',
  'iat': int(time.time()),
  'exp': int(time.time()) + 10*365*86400
}, os.environ['JWT_SECRET'], algorithm='HS256'))
PY
)
set_secret "SUPABASE-SERVICE-KEY" "$SERVICE_KEY"

echo
echo "═══════════════════════════════════════════════"
echo "  ✅ Bootstrap secrets ready in $KEY_VAULT"
echo "═══════════════════════════════════════════════"
az keyvault secret list --vault-name "$KEY_VAULT" --query "[].name" -o tsv
echo
echo "⚠️  Each deployment needs its OWN unique JWT secret."
echo "   Never reuse these values across two different instances."
echo
echo "Next: cd terraform && terraform apply"
