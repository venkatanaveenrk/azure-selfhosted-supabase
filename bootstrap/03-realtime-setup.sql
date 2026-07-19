-- ================================================================
-- Supabase Database Bootstrap — 03-realtime-setup.sql  (v3)
-- ================================================================
-- Configures PostgreSQL logical replication for Supabase Realtime.
--
-- Realtime works by listening to a Postgres PUBLICATION via a
-- replication slot. When rows change in published tables, Postgres
-- streams the change and Realtime pushes it to subscribed clients.
--
-- Prerequisite: wal_level = logical (Terraform sets this server
-- parameter; requires a server restart which Azure handles).
-- ================================================================

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────
-- THE REALTIME PUBLICATION
-- ────────────────────────────────────────────────
-- Supabase's standard publication name is 'supabase_realtime'.
-- Created empty here; tables are added to it on demand — either by
-- developers, or by Studio when they toggle Realtime for a table.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) THEN
    -- Empty publication. Add tables later with:
    --   ALTER PUBLICATION supabase_realtime ADD TABLE public.my_table;
    CREATE PUBLICATION supabase_realtime;
    RAISE NOTICE '  Created empty publication: supabase_realtime';
  ELSE
    RAISE NOTICE '  Publication supabase_realtime already exists';
  END IF;
END
$$;

-- ────────────────────────────────────────────────
-- REALTIME SCHEMA PERMISSIONS
-- ────────────────────────────────────────────────
-- The realtime service stores its own metadata in the realtime schema.
GRANT ALL ON SCHEMA realtime  TO supabase_realtime_admin;
GRANT ALL ON SCHEMA _realtime TO supabase_realtime_admin;

-- supabase_realtime_admin needs to read replication state
ALTER ROLE supabase_realtime_admin WITH REPLICATION;

-- API roles need to read realtime schema (for RLS on realtime messages)
GRANT USAGE ON SCHEMA realtime TO anon, authenticated, service_role;

-- ────────────────────────────────────────────────
-- HELPER: add a table to realtime (for convenience)
-- ────────────────────────────────────────────────
-- Devs / Studio can call:  SELECT realtime.enable_table('public','orders');
CREATE OR REPLACE FUNCTION realtime.enable_table(
  target_schema text,
  target_table  text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  EXECUTE format(
    'ALTER PUBLICATION supabase_realtime ADD TABLE %I.%I',
    target_schema, target_table
  );
  -- REPLICA IDENTITY FULL ensures UPDATE/DELETE payloads include old values
  EXECUTE format(
    'ALTER TABLE %I.%I REPLICA IDENTITY FULL',
    target_schema, target_table
  );
  RAISE NOTICE 'Realtime enabled for %.%', target_schema, target_table;
END
$$;

GRANT EXECUTE ON FUNCTION realtime.enable_table(text, text) TO service_role;

DO $$
BEGIN
  RAISE NOTICE '✓ 03-realtime-setup.sql complete';
  RAISE NOTICE '  Publication: supabase_realtime (empty — add tables on demand)';
  RAISE NOTICE '  Helper: realtime.enable_table(schema, table)';
  RAISE NOTICE '  Bootstrap COMPLETE. Database is ready for Supabase services.';
END
$$;
