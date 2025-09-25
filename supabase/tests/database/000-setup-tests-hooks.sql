-- Pre-test setup hook - runs automatically before all other tests
-- This file is named with 000- prefix to ensure it runs first

-- Install pgtap extension for testing
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Create test helper schemas
CREATE SCHEMA IF NOT EXISTS tests;
CREATE SCHEMA IF NOT EXISTS test_overrides;

-- Grant permissions for test schemas
GRANT USAGE ON SCHEMA tests TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA tests REVOKE EXECUTE ON FUNCTIONS FROM public;
ALTER DEFAULT PRIVILEGES IN SCHEMA tests GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

GRANT USAGE ON SCHEMA test_overrides TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA test_overrides REVOKE EXECUTE ON FUNCTIONS FROM public;
ALTER DEFAULT PRIVILEGES IN SCHEMA test_overrides GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

-- Create test helper functions
CREATE OR REPLACE FUNCTION tests.create_supabase_user(identifier text, email text default null, phone text default null, metadata jsonb default null)
RETURNS uuid
    SECURITY DEFINER
    SET search_path = auth, pg_temp
AS $$
DECLARE
    user_id uuid;
BEGIN
    user_id := extensions.uuid_generate_v4();
    INSERT INTO auth.users (id, email, phone, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
    VALUES (user_id, coalesce(email, concat(user_id, '@test.com')), phone, jsonb_build_object('test_identifier', identifier) || coalesce(metadata, '{}'::jsonb), '{}'::jsonb, pg_catalog.now(), pg_catalog.now())
    RETURNING id INTO user_id;
    RETURN user_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.get_supabase_user(identifier text)
RETURNS json
SECURITY DEFINER
SET search_path = auth, pg_temp
AS $$
    DECLARE
        supabase_user json;
    BEGIN
        SELECT json_build_object(
        'id', id,
        'email', email,
        'phone', phone,
        'raw_user_meta_data', raw_user_meta_data,
        'raw_app_meta_data', raw_app_meta_data
        ) into supabase_user
        FROM auth.users
        WHERE raw_user_meta_data ->> 'test_identifier' = identifier limit 1;
        
        if supabase_user is null OR supabase_user -> 'id' IS NULL then
            RAISE EXCEPTION 'User with identifier % not found', identifier;
        end if;
        RETURN supabase_user;
    END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.get_supabase_uid(identifier text)
    RETURNS uuid
    SECURITY DEFINER
    SET search_path = auth, pg_temp
AS $$
DECLARE
    supabase_user uuid;
BEGIN
    SELECT id into supabase_user FROM auth.users WHERE raw_user_meta_data ->> 'test_identifier' = identifier limit 1;
    if supabase_user is null then
        RAISE EXCEPTION 'User with identifier % not found', identifier;
    end if;
    RETURN supabase_user;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.authenticate_as (identifier text)
    RETURNS void
    AS $$
        DECLARE
                user_data json;
                original_auth_data text;
        BEGIN
            original_auth_data := current_setting('request.jwt.claims', true);
            user_data := tests.get_supabase_user(identifier);

            if user_data is null OR user_data ->> 'id' IS NULL then
                RAISE EXCEPTION 'User with identifier % not found', identifier;
            end if;

            perform set_config('role', 'authenticated', true);
            perform set_config('request.jwt.claims', json_build_object(
                'sub', user_data ->> 'id', 
                'email', user_data ->> 'email', 
                'phone', user_data ->> 'phone', 
                'user_metadata', user_data -> 'raw_user_meta_data', 
                'app_metadata', user_data -> 'raw_app_meta_data'
            )::text, true);

        EXCEPTION
            WHEN OTHERS THEN
                set local role authenticated;
                set local "request.jwt.claims" to original_auth_data;
                RAISE;
        END
    $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.clear_authentication()
    RETURNS void AS $$
BEGIN
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', null, true);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.authenticate_as_service_role ()
    RETURNS void
    AS $$
        BEGIN
            perform set_config('role', 'service_role', true);
            perform set_config('request.jwt.claims', null, true);
        END
    $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.rls_enabled (testing_schema text)
RETURNS text AS $$
    select is(
        (select
                count(pc.relname)::integer
           from pg_class pc
           join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = rls_enabled.testing_schema
           join pg_type pt on pt.oid = pc.reltype
           where relrowsecurity = FALSE)
        ,
        0,
        'All tables in the' || testing_schema || ' schema should have row level security enabled');
$$ LANGUAGE sql;

-- Time manipulation functions for testing
CREATE OR REPLACE FUNCTION test_overrides.now()
    RETURNS timestamp with time zone
AS $$
BEGIN
    IF nullif(current_setting('tests.frozen_time'), '') IS NOT NULL THEN
        RETURN current_setting('tests.frozen_time')::timestamptz;
    END IF;
    RETURN pg_catalog.now();
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.freeze_time(frozen_time timestamp with time zone)
    RETURNS void
AS $$
BEGIN
    IF current_setting('search_path') NOT LIKE 'test_overrides,%' THEN
        PERFORM set_config('tests.original_search_path', current_setting('search_path'), true);
        PERFORM set_config('search_path', 'test_overrides,' || current_setting('tests.original_search_path') || ',pg_catalog', true);
    END IF;
    PERFORM set_config('tests.frozen_time', frozen_time::text, true);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.unfreeze_time()
    RETURNS void
AS $$
BEGIN
    PERFORM set_config('tests.frozen_time', null, true);
    PERFORM set_config('search_path', current_setting('tests.original_search_path'), true);
END
$$ LANGUAGE plpgsql;

-- Verify setup with a no-op test
SELECT plan(1);
SELECT ok(true, 'Pre-test hook completed successfully');
SELECT * FROM finish();
