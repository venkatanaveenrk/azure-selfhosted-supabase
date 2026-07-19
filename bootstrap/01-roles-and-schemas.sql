-- ================================================================
-- Supabase Database Bootstrap — 01-roles-and-schemas.sql  (v3)
-- ================================================================
-- Mounted at /docker-entrypoint-initdb.d by docker-compose so Postgres
-- runs it ONCE on initial database creation (i.e. when PGDATA is empty).
-- Re-running it manually is also safe: every statement is idempotent.
--
-- Creates the roles, schemas, helper functions, and grants every
-- Supabase service depends on.
--
-- The role/schema setup below is the result of trial-and-error. Each
-- block is deliberate — don't simplify without understanding why.
-- ================================================================

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────
-- EXTENSIONS
-- ────────────────────────────────────────────────
-- Installed into a dedicated 'extensions' schema so they don't clutter
-- 'public'.
CREATE SCHEMA IF NOT EXISTS extensions;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp"          SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgcrypto"           SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgjwt"              SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "citext"             SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "hstore"             SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pg_trgm"            SCHEMA extensions;
-- pgvector — for embeddings / AI workloads (supabase/postgres image ships it)
CREATE EXTENSION IF NOT EXISTS "vector"             SCHEMA extensions;

-- ────────────────────────────────────────────────
-- CORE ROLES
-- ────────────────────────────────────────────────
-- Supabase's auth model is built on these Postgres roles. PostgREST
-- and GoTrue switch into them depending on the JWT 'role' claim.
--
--   anon                     — unauthenticated public requests
--   authenticated            — logged-in users
--   service_role             — backend god-mode (bypasses RLS)
--   authenticator            — login role PostgREST connects AS
--   supabase_admin           — owns everything (superuser)
--   supabase_auth_admin      — owns the auth schema (GoTrue)
--   supabase_storage_admin   — owns the storage schema (Storage API)
--   supabase_realtime_admin  — owns the realtime + _realtime schemas
--   postgres                 — placeholder role (NOLOGIN, see below)

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;

  -- authenticator: PostgREST connects as this and SETs the request role
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;

  -- Per-service admin roles
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin LOGIN NOINHERIT CREATEROLE;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin LOGIN NOINHERIT CREATEROLE;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_realtime_admin') THEN
    CREATE ROLE supabase_realtime_admin LOGIN NOINHERIT;
  END IF;

  -- ───────────── placeholder 'postgres' role ─────────────
  -- GoTrue migration 20240612123726_enable_rls_update_grants hardcodes
  -- "GRANT ... TO postgres" without checking whether the role exists.
  -- We create a NOLOGIN placeholder so the grant succeeds. The role
  -- inherits from supabase_admin so it has appropriate privileges if
  -- ever needed for compatibility paths.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres NOLOGIN INHERIT;
    GRANT supabase_admin TO postgres;
  END IF;
END
$$;

-- authenticator can switch into the three request roles
GRANT anon, authenticated, service_role TO authenticator;

-- The current admin user can also assume them (useful for SQL editor)
DO $$
DECLARE
  current_admin text := current_user;
BEGIN
  EXECUTE format('GRANT anon, authenticated, service_role TO %I', current_admin);
END
$$;

-- ────────────────────────────────────────────────
-- SCHEMAS
-- ────────────────────────────────────────────────
-- Each Supabase service owns its own schema, authored by the matching
-- admin role. CREATE SCHEMA ... AUTHORIZATION sets the owner so the
-- service can create tables/functions inside without further grants.
CREATE SCHEMA IF NOT EXISTS auth      AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA IF NOT EXISTS storage   AUTHORIZATION supabase_storage_admin;
CREATE SCHEMA IF NOT EXISTS realtime  AUTHORIZATION supabase_realtime_admin;
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_realtime_admin;
CREATE SCHEMA IF NOT EXISTS graphql_public;

-- ───────────── explicit ownership + ALL grants ─────────────
-- Even with AUTHORIZATION at creation, some Supabase service migrations
-- run as their own role and need explicit ALL ON SCHEMA. Setting these
-- a second time is a no-op if already correct.
ALTER SCHEMA auth      OWNER TO supabase_auth_admin;
ALTER SCHEMA storage   OWNER TO supabase_storage_admin;
ALTER SCHEMA realtime  OWNER TO supabase_realtime_admin;
ALTER SCHEMA _realtime OWNER TO supabase_realtime_admin;

GRANT ALL ON SCHEMA auth      TO supabase_auth_admin;
GRANT ALL ON SCHEMA storage   TO supabase_storage_admin;
GRANT ALL ON SCHEMA realtime  TO supabase_realtime_admin;
GRANT ALL ON SCHEMA _realtime TO supabase_realtime_admin;

-- ───────────── CREATE on database for service admins ─────
-- The GoTrue/Storage/Realtime migrations occasionally CREATE objects
-- at database scope (extensions, custom types). They need CREATE on
-- the database itself in addition to schema-level grants.
GRANT CREATE ON DATABASE postgres TO
  supabase_auth_admin,
  supabase_storage_admin,
  supabase_realtime_admin,
  authenticator;

-- ────────────────────────────────────────────────
-- SCHEMA USAGE GRANTS
-- ────────────────────────────────────────────────
-- public schema — API roles need access
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- extensions schema — readable by API roles
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- auth schema — API roles need USAGE for auth.uid() etc.
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- storage schema — API roles interact via storage-api
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

-- graphql_public — for pg_graphql resolver
GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;

-- ────────────────────────────────────────────────
-- HELPER FUNCTIONS — auth.uid() / auth.role() / auth.email() / auth.jwt()
-- ────────────────────────────────────────────────
-- These let RLS policies read the current request's JWT claims.
-- e.g.  CREATE POLICY ... USING (user_id = auth.uid());
--
-- ───────────── function ownership ─────────────
-- These functions MUST be owned by supabase_auth_admin so the auth
-- service's own migrations can ALTER/replace them later. We use SET
-- ROLE inside a DO block so the CREATE OR REPLACE runs as that owner.

DO $$
BEGIN
  -- Switch to the auth admin so functions are created with that ownership.
  SET LOCAL ROLE supabase_auth_admin;

  CREATE OR REPLACE FUNCTION auth.uid()
  RETURNS uuid
  LANGUAGE sql STABLE
  AS $func$
    SELECT COALESCE(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  $func$;

  CREATE OR REPLACE FUNCTION auth.role()
  RETURNS text
  LANGUAGE sql STABLE
  AS $func$
    SELECT COALESCE(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    )::text
  $func$;

  CREATE OR REPLACE FUNCTION auth.email()
  RETURNS text
  LANGUAGE sql STABLE
  AS $func$
    SELECT COALESCE(
      nullif(current_setting('request.jwt.claim.email', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
    )::text
  $func$;

  CREATE OR REPLACE FUNCTION auth.jwt()
  RETURNS jsonb
  LANGUAGE sql STABLE
  AS $func$
    SELECT COALESCE(
      nullif(current_setting('request.jwt.claim', true), ''),
      nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
  $func$;
END
$$;

-- Belt-and-braces: explicitly set ownership (in case the SET LOCAL
-- ROLE didn't apply, e.g. when this script is re-run by a different
-- user).
ALTER FUNCTION auth.uid()   OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.role()  OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.email() OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.jwt()   OWNER TO supabase_auth_admin;

-- API roles may execute the helpers
GRANT EXECUTE ON FUNCTION auth.uid()   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role()  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.email() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt()   TO anon, authenticated, service_role;

-- ────────────────────────────────────────────────
-- DONE
-- ────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '✓ 01-roles-and-schemas.sql complete';
  RAISE NOTICE '  Roles: anon, authenticated, service_role, authenticator,';
  RAISE NOTICE '         supabase_auth_admin, supabase_storage_admin, supabase_realtime_admin, postgres';
  RAISE NOTICE '  Schemas: auth, storage, realtime, _realtime, extensions, graphql_public';
  RAISE NOTICE '  Next: 02-service-passwords.sql will set login passwords (SCRAM)';
END
$$;
