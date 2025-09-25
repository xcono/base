create extension if not exists pgtap with schema extensions;

-- Load our local test helpers
\i supabase/test_helpers.sql