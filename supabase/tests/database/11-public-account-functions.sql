BEGIN;
create extension "basejump-supabase_test_helpers" version '0.0.6';

select plan(29);

--- we insert a user into auth.users and return the id into user_id to use
select tests.create_supabase_user('test1');
select tests.create_supabase_user('test2');
select tests.create_supabase_user('test_member');

select tests.authenticate_as('test1');
select create_team('my-account', 'My account');
select create_team(name => 'My Account 2', slug => 'my-account-2');

select is(
               (select (get_team_by_slug('my-account') ->> 'team_id')::uuid),
               (select id from tenancy.teams where slug = 'my-account'),
               'get_team_by_slug returns the correct team_id'
           );

select is(
               (select json_array_length(get_teams())),
               3,
               'get_teams returns 2 teams'
           );


-- insert known account id into accounts table for testing later
insert into tenancy.teams (id, slug, name)
values ('00000000-0000-0000-0000-000000000000', 'my-known-account', 'My Known Account');

-- get_account_id should return the correct account id
select is(
               (select public.get_team_id('my-known-account')),
               '00000000-0000-0000-0000-000000000000'::uuid,
               'get_team_id should return the correct id'
           );

select is(
               (select (public.get_team('00000000-0000-0000-0000-000000000000') ->> 'team_id')::uuid),
               '00000000-0000-0000-0000-000000000000'::uuid,
               'get_team should be able to return a known team'
           );

----- updating accounts should work
select update_team('00000000-0000-0000-0000-000000000000', slug => 'my-updated-slug');

select is(
               (select slug from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               'my-updated-slug',
               'Updating slug should have been successful for the owner'
           );

select update_team('00000000-0000-0000-0000-000000000000', name => 'My Updated Account Name');

select is(
               (select name from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               'My Updated Account Name',
               'Updating team name should have been successful for the owner'
           );

select update_team('00000000-0000-0000-0000-000000000000', public_metadata => jsonb_build_object('foo', 'bar'));

select is(
               (select public_metadata from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               '{
                 "foo": "bar"
               }'::jsonb,
               'Updating meta should have been successful for the owner'
           );

select update_team('00000000-0000-0000-0000-000000000000', public_metadata => jsonb_build_object('foo', 'bar2'));

select is(
               (select public_metadata from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               '{
                 "foo": "bar2"
               }'::jsonb,
               'Updating meta should have been successful for the owner'
           );

select update_team('00000000-0000-0000-0000-000000000000', public_metadata => jsonb_build_object('foo2', 'bar'));

select is(
               (select public_metadata from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               '{
                 "foo": "bar2",
                 "foo2": "bar"
               }'::jsonb,
               'Updating meta should have merged by default'
           );

select update_team('00000000-0000-0000-0000-000000000000', public_metadata => jsonb_build_object('foo3', 'bar'),
                      replace_metadata => true);

select is(
               (select public_metadata from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               '{
                 "foo3": "bar"
               }'::jsonb,
               'Updating meta should support replacing when you want'
           );

-- get_account should return public metadata
select is(
               (select (get_team('00000000-0000-0000-0000-000000000000') ->> 'metadata')::jsonb),
               '{
                 "foo3": "bar"
               }'::jsonb,
               'get_account should return public metadata'
           );

select update_team('00000000-0000-0000-0000-000000000000', name => 'My Updated Account Name 2');

select is(
               (select public_metadata from tenancy.teams where id = '00000000-0000-0000-0000-000000000000'),
               '{
                 "foo3": "bar"
               }'::jsonb,
               'Updating other fields should not affect public metadata'
           );

--- test that we cannot update accounts we belong to but don't own

select tests.clear_authentication();
set role postgres;

insert into tenancy.team_user (team_id, team_role, user_id)
values ('00000000-0000-0000-0000-000000000000', 'member', tests.get_supabase_uid('test_member'));

select tests.authenticate_as('test_member');

select throws_ok(
               $$select update_team('00000000-0000-0000-0000-000000000000', slug => 'my-updated-slug-200')$$,
               'Only team owners can update a team'
           );
-------
--- Second user
-------

select tests.authenticate_as('test2');

select throws_ok(
               $$select get_team('00000000-0000-0000-0000-000000000000')$$,
               'Not found'
           );

select throws_ok(
               $$select get_team_by_slug('my-known-account')$$,
               'Not found'
           );

select throws_ok(
               $$select current_user_team_role('00000000-0000-0000-0000-000000000000')$$,
               'Not found'
           );

select is(
               (select json_array_length(get_teams())),
               1,
               'get_teams returns 1 teams (default)'
           );

select is(
               (select get_team(auth.uid()) ->> 'team_id'),
               auth.uid()::text,
               'get_team should return the correct team_id for user default team'
           );


select throws_ok($$select create_team('my-account', 'My account')$$,
                 'A team with that unique ID already exists');

select create_team('My AccOunt & 3');

select is(
               (select (get_team_by_slug('my-account-3') ->> 'team_id')::uuid),
               (select id from tenancy.teams where slug = 'my-account-3'),
               'get_team_by_slug returns the correct team_id'
           );

select is(
               (select json_array_length(get_teams())),
               2,
               'get_teams returns 2 teams (default and team)'
           );


-- Should not be able to update an account you aren't a member of

select throws_ok(
               $$select update_team('00000000-0000-0000-0000-000000000000', slug => 'my-account-new-slug')$$,
               'Not found'
           );

-- Anon users should not have access to any of these functions

select tests.clear_authentication();

select throws_ok(
               $$select get_team('00000000-0000-0000-0000-000000000000')$$,
               'permission denied for function get_team'
           );

select throws_ok(
               $$select get_team_by_slug('my-account-3')$$,
               'permission denied for function get_team_by_slug'
           );

select throws_ok(
               $$select current_user_team_role('00000000-0000-0000-0000-000000000000')$$,
               'permission denied for function current_user_team_role'
           );

select throws_ok(
               $$select get_teams()$$,
               'permission denied for function get_teams'
           );


---- some functions should work for service_role users
select tests.authenticate_as_service_role();

select is(
               (select (get_team('00000000-0000-0000-0000-000000000000') ->> 'team_id')::uuid),
               '00000000-0000-0000-0000-000000000000'::uuid,
               'get_team should return the correct team_id'
           );

select is(
               (select (get_team_by_slug('my-updated-slug') ->> 'team_id')::uuid),
               (select id from tenancy.teams where slug = 'my-updated-slug'),
               'get_team_by_slug returns the correct team_id'
           );

select update_team('00000000-0000-0000-0000-000000000000', slug => 'my-updated-slug-300');

select is(
               (select get_team('00000000-0000-0000-0000-000000000000') ->> 'slug'),
               'my-updated-slug-300',
               'Updating the team slug should work for service_role users'
           );

SELECT *
FROM finish();

ROLLBACK;