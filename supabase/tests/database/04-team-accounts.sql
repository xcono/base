BEGIN;
create extension "basejump-supabase_test_helpers" version '0.0.6';

select plan(33);

-- make sure we're setup for enabling personal accounts
update tenancy.config
set service_name = 'supabase';

-- Create the users we plan on using for testing
select tests.create_supabase_user('test1');
select tests.create_supabase_user('test2');
select tests.create_supabase_user('test_member');
select tests.create_supabase_user('test_owner');
select tests.create_supabase_user('test_random_owner');

--- start acting as an authenticated user
select tests.authenticate_as('test_random_owner');

-- setup inaccessible tests for a known account ID
insert into tenancy.teams (id, name, slug)
values ('d126ecef-35f6-4b5d-9f28-d9f00a9fb46f', 'nobody in test can access me', 'no-access');

------------
--- Primary Owner
------------
select tests.authenticate_as('test1');

-- should be able to create a team account when they're enabled
SELECT row_eq(
               $$ insert into tenancy.teams (id, name, slug) values ('8fcec130-27cd-4374-9e47-3303f9529479', 'test team', 'test-team') returning 1$$,
               ROW (1),
               'Should be able to create a new team'
           );

-- newly created team should be owned by current user
SELECT row_eq(
               $$ select primary_owner_user_id from tenancy.teams where id = '8fcec130-27cd-4374-9e47-3303f9529479' $$,
               ROW (tests.get_supabase_uid('test1')),
               'Creating a new team should make the current user the primary owner'
           );

-- should add that user to the account as an owner
SELECT row_eq(
               $$ select user_id, team_role from tenancy.team_user where team_id = '8fcec130-27cd-4374-9e47-3303f9529479'::uuid $$,
               ROW (tests.get_supabase_uid('test1'), 'owner'::tenancy.team_role),
               'Inserting a team should also add a team_user for the current user'
           );

-- should be able to get your own role for the account
SELECT row_eq(
               $$ select public.current_user_team_role('8fcec130-27cd-4374-9e47-3303f9529479') $$,
               ROW (jsonb_build_object(
                       'team_role', 'owner',
                       'is_primary_owner', TRUE
                   )),
               'Primary owner should be able to get their own role'
           );

-- cannot change the accounts.primary_owner_user_id directly
SELECT throws_ok(
               $$ update tenancy.teams set primary_owner_user_id = tests.get_supabase_uid('test2') where id = '8fcec130-27cd-4374-9e47-3303f9529479' $$,
               'You do not have permission to update this field'
           );

-- cannot delete the primary_owner_user_id from the account_user table
select row_eq(
               $$
    	delete from tenancy.team_user where user_id = tests.get_supabase_uid('test1');
    	select user_id from tenancy.team_user where user_id = tests.get_supabase_uid('test1');
    $$,
               ROW (tests.get_supabase_uid('test1')::uuid),
               'Should not be able to delete the primary_owner_user_id from the team_user table'
           );

-- owners should be able to add invitations
SELECT row_eq(
               $$ insert into tenancy.invitations (team_id, team_role, token, invitation_type) values ('8fcec130-27cd-4374-9e47-3303f9529479', 'member', 'test_member_single_use_token', 'one_time') returning 1 $$,
               ROW (1),
               'Owners should be able to add invitations for new members'
           );

SELECT row_eq(
               $$ insert into tenancy.invitations (team_id, team_role, token, invitation_type) values ('8fcec130-27cd-4374-9e47-3303f9529479', 'owner', 'test_owner_single_use_token', 'one_time') returning 1 $$,
               ROW (1),
               'Owners should be able to add invitations for new owners'
           );

-- should not be able to add new users directly into team accounts
SELECT throws_ok(
               $$ insert into tenancy.team_user (team_id, team_role, user_id) values ('8fcec130-27cd-4374-9e47-3303f9529479', 'owner', tests.get_supabase_uid('test2')) $$,
               'new row violates row-level security policy for table "team_user"'
           );


-- owner can update their team name
SELECT results_eq(
               $$ update tenancy.teams set name = 'test' where id = '8fcec130-27cd-4374-9e47-3303f9529479' returning name $$,
               $$ values('test') $$,
               'Owner can update their team name'
           );

-- all accounts (personal and team) should be returned by get_accounts_with_role test
SELECT ok(
               (select '8fcec130-27cd-4374-9e47-3303f9529479' IN
                       (select tenancy.get_teams_with_role())),
               'Team should be returned by the tenancy.get_teams_with_role function'
           );

-- shouoldn't return any accounts if you're not a member of
SELECT ok(
               (select 'd126ecef-35f6-4b5d-9f28-d9f00a9fb46f' NOT IN
                       (select tenancy.get_teams_with_role())),
               'Teams not a member of should NOT be returned by the tenancy.get_teams_with_role function'
           );

-- should return true for tenancy.has_role_on_team
SELECT ok(
               (select tenancy.has_role_on_team('8fcec130-27cd-4374-9e47-3303f9529479', 'owner')),
               'Should return true for tenancy.has_role_on_team'
           );

SELECT ok(
               (select tenancy.has_role_on_team('8fcec130-27cd-4374-9e47-3303f9529479')),
               'Should return true for tenancy.has_role_on_team'
           );

-- should return FALSE when not on the team
SELECT ok(
               (select NOT tenancy.has_role_on_team('d126ecef-35f6-4b5d-9f28-d9f00a9fb46f')),
               'Should return false for tenancy.has_role_on_team'
           );

-----------
--- Account User Setup
-----------
select tests.clear_authentication();
set role postgres;

-- insert account_user for the member test
insert into tenancy.team_user (team_id, team_role, user_id)
values ('8fcec130-27cd-4374-9e47-3303f9529479', 'member', tests.get_supabase_uid('test_member'));
-- insert account_user for the owner test
insert into tenancy.team_user (team_id, team_role, user_id)
values ('8fcec130-27cd-4374-9e47-3303f9529479', 'owner', tests.get_supabase_uid('test_owner'));

-----------
--- Member
-----------
select tests.authenticate_as('test_member');

-- should now have access to the team
SELECT is(
               (select count(*)::int from tenancy.teams where id = '8fcec130-27cd-4374-9e47-3303f9529479'),
               1,
               'Should now have access to the team'
           );

-- members cannot update account info
SELECT results_ne(
               $$ update tenancy.teams set name = 'test' where id = '8fcec130-27cd-4374-9e47-3303f9529479' returning 1 $$,
               $$ values(1) $$,
               'Member cannot update their team name'
           );

-- account_user should have a role of member
SELECT row_eq(
               $$ select team_role from tenancy.team_user where team_id = '8fcec130-27cd-4374-9e47-3303f9529479' and user_id = tests.get_supabase_uid('test_member')$$,
               ROW ('member'::tenancy.team_role),
               'Should have the correct team role after accepting an invitation'
           );

-- should be able to get your own role for the account
SELECT row_eq(
               $$ select public.current_user_team_role('8fcec130-27cd-4374-9e47-3303f9529479') $$,
               ROW (jsonb_build_object(
                       'team_role', 'member',
                       'is_primary_owner', FALSE
                   )),
               'Member should be able to get their own role'
           );

-- Should NOT show up as an owner in the permissions check
SELECT ok(
               (select '8fcec130-27cd-4374-9e47-3303f9529479' NOT IN
                       (select tenancy.get_teams_with_role('owner'))),
               'Newly added team ID should not be in the list of teams returned by tenancy.get_teams_with_role("owner")'
           );

-- Should be able ot get a full list of accounts when no permission passed in
SELECT ok(
               (select '8fcec130-27cd-4374-9e47-3303f9529479' IN
                       (select tenancy.get_teams_with_role())),
               'Newly added team ID should be in the list of teams returned by tenancy.get_teams_with_role()'
           );

-- should return true for tenancy.has_role_on_team
SELECT ok(
               (select tenancy.has_role_on_team('8fcec130-27cd-4374-9e47-3303f9529479')),
               'Should return true for tenancy.has_role_on_team'
           );

-- should return false for the owner lookup
SELECT ok(
               (select NOT tenancy.has_role_on_team('8fcec130-27cd-4374-9e47-3303f9529479', 'owner')),
               'Should return false for tenancy.has_role_on_team'
           );

-----------
--- Non-Primary Owner
-----------
select tests.authenticate_as('test_owner');

-- should now have access to the team
SELECT is(
               (select count(*)::int from tenancy.teams where id = '8fcec130-27cd-4374-9e47-3303f9529479'),
               1,
               'Should now have access to the team'
           );

-- account_user should have a role of member
SELECT row_eq(
               $$ select team_role from tenancy.team_user where team_id = '8fcec130-27cd-4374-9e47-3303f9529479' and user_id = tests.get_supabase_uid('test_owner')$$,
               ROW ('owner'::tenancy.team_role),
               'Should have the expected team role'
           );

-- should be able to get your own role for the account
SELECT row_eq(
               $$ select public.current_user_team_role('8fcec130-27cd-4374-9e47-3303f9529479') $$,
               ROW (jsonb_build_object(
                       'team_role', 'owner',
                       'is_primary_owner', FALSE
                   )),
               'Owner should be able to get their own role'
           );

-- Should NOT show up as an owner in the permissions check
SELECT ok(
               (select '8fcec130-27cd-4374-9e47-3303f9529479' IN
                       (select tenancy.get_teams_with_role('owner'))),
               'Newly added team ID should be in the list of teams returned by tenancy.get_teams_with_role("owner")'
           );

-- Should be able ot get a full list of accounts when no permission passed in
SELECT ok(
               (select '8fcec130-27cd-4374-9e47-3303f9529479' IN
                       (select tenancy.get_teams_with_role())),
               'Newly added team ID should be in the list of teams returned by tenancy.get_teams_with_role()'
           );

SELECT results_eq(
               $$ update tenancy.teams set name = 'test2' where id = '8fcec130-27cd-4374-9e47-3303f9529479' returning name $$,
               $$ values('test2') $$,
               'New owners can update their team name'
           );

-----------
-- Strangers
----------

select tests.authenticate_as('test2');

-- non members / owner cannot update team name
SELECT results_ne(
               $$ update tenancy.teams set name = 'test3' where id = '8fcec130-27cd-4374-9e47-3303f9529479' returning 1$$,
               $$ select 1 $$
           );
-- non member / owner should only see their own default team
SELECT is(
               (select count(*)::int from tenancy.teams),
               1,
               'Non members / owner should only see their own default team'
           );

--------------
-- Anonymous
--------------
select tests.clear_authentication();

-- anonymous should receive no results from accounts
SELECT throws_ok(
               $$ select * from tenancy.teams $$,
               'permission denied for schema tenancy'
           );

-- anonymous cannot update team name
SELECT throws_ok(
               $$ update tenancy.teams set name = 'test' returning 1 $$,
               'permission denied for schema tenancy'
           );

SELECT *
FROM finish();

ROLLBACK;