# Bootstrap SQL

These files are mounted into the PostgreSQL container at
`/docker-entrypoint-initdb.d/`. Postgres runs them in **alphabetical
order** on first init (when `PGDATA` is empty).

| File | Purpose |
|------|---------|
| `01-roles-and-schemas.sql` | Roles, schemas, extensions, `auth.uid()` helpers |
| `02-service-passwords.sql.template` | TEMPLATE — never executed directly |
| `02-service-passwords.sql` | Rendered from the template by `deploy-stack.sh`. Gitignored. |
| `03-realtime-setup.sql` | Realtime publication + helper function |

## The `.template` pattern

Postgres' init scripts don't accept `psql -v VAR=value` substitution.
We therefore keep a `.template` file with `:'placeholder'` markers in
git and have `deploy-stack.sh` render a concrete `.sql` file from it,
substituting the real passwords fetched from Key Vault.

Add `02-service-passwords.sql` to `.gitignore` — it contains plaintext
passwords after rendering and must not be committed.

## Re-running

The init scripts only run on a *fresh* database. To re-apply (e.g.,
after a fix), connect with `psql` as `supabase_admin` and execute
manually:

```bash
psql "postgres://supabase_admin@/postgres" -f 01-roles-and-schemas.sql
```

All statements are idempotent (use `IF NOT EXISTS`, `CREATE OR REPLACE`,
or `ALTER` of already-correct values).
