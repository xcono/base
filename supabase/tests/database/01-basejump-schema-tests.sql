BEGIN;
create extension "basejump-supabase_test_helpers" version '0.0.6';

 select plan(18);

select has_schema('tenancy', 'Basejump schema should exist');

select has_table('tenancy', 'config', 'Basejump config table should exist');
select has_table('tenancy', 'teams', 'Basejump teams table should exist');
select has_table('tenancy', 'team_user', 'Basejump team_users table should exist');
select has_table('tenancy', 'invitations', 'Basejump invitations table should exist');
select has_table('tenancy', 'billing_customers', 'Basejump billing_customers table should exist');
select has_table('tenancy', 'billing_subscriptions', 'Basejump billing_subscriptions table should exist');

select tests.rls_enabled('tenancy');

select columns_are('tenancy', 'config',
                   Array ['service_name'],
                   'Basejump config table should have the correct columns');


select function_returns('tenancy', 'generate_token', Array ['integer'], 'text',
                        'Basejump generate_token function should exist');
select function_returns('tenancy', 'trigger_set_timestamps', 'trigger',
                        'Basejump trigger_set_timestamps function should exist');

SELECT schema_privs_are('tenancy', 'anon', Array [NULL], 'Anon should not have access to tenancy schema');

-- set the role to anonymous for verifying access tests
set role anon;
select throws_ok('select tenancy.get_config()');
select throws_ok('select tenancy.generate_token(1)');

-- set the role to the service_role for testing access
set role service_role;
select ok(tenancy.get_config() is not null),
       'Basejump get_config should be accessible to the service role';

-- set the role to authenticated for tests
set role authenticated;
select ok(tenancy.get_config() is not null), 'Basejump get_config should be accessible to authenticated users';
select ok(tenancy.generate_token(1) is not null),
       'Basejump generate_token should be accessible to authenticated users';
select isnt_empty('select * from tenancy.config', 'authenticated users should have access to Basejump config');

SELECT *
FROM finish();

ROLLBACK;