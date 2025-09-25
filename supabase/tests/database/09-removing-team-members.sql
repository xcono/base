BEGIN;
create extension "basejump-supabase_test_helpers" version '0.0.6';

select plan(6);


-- create the users we need for testing
select tests.create_supabase_user('primary_owner');
select tests.create_supabase_user('invited_owner');
select tests.create_supabase_user('member');
select tests.create_supabase_user('testing_member');

--- Setup the tests
select tests.authenticate_as('primary_owner');
select create_team('test', 'Test Team');

set role postgres;

insert into tenancy.team_user (team_id, team_role, user_id)
values (get_team_id('test'), 'member', tests.get_supabase_uid('member'));
insert into tenancy.team_user (team_id, team_role, user_id)
values (get_team_id('test'), 'owner', tests.get_supabase_uid('invited_owner'));
insert into tenancy.team_user (team_id, team_role, user_id)
values (get_team_id('test'), 'member', tests.get_supabase_uid('testing_member'));

---  can NOT remove a member unless your an owner
select tests.authenticate_as('member');

SELECT throws_ok(
               $$ select remove_team_member(get_team_id('test'), tests.get_supabase_uid('testing_member')) $$,
               'Only team owners can access this function'
           );

--- CAN remove a member if you're an owner
select tests.authenticate_as('invited_owner');

select lives_ok(
               $$select remove_team_member(get_team_id('test'), tests.get_supabase_uid('testing_member'))$$,
               'Owners should be able to remove members'
           );

select tests.authenticate_as('testing_member');

SELECT is(
               (select tenancy.has_role_on_team(get_team_id('test'))),
               false,
               'Should no longer have access to the team'
           );

--- can NOT remove the primary owner
select tests.authenticate_as('invited_owner');

--- attempt to delete primary owner
select remove_team_member(get_team_id('test'), tests.get_supabase_uid('primary_owner'));

--- CAN remove ANOTHER owner as an owner as long as that owner is NOT the primary owner

select tests.authenticate_as('primary_owner');

SELECT is(
               (select tenancy.has_role_on_team(get_team_id('test'), 'owner')),
               true,
               'Primary owner should still be on the account'
           );

select lives_ok(
               $$select remove_team_member(get_team_id('test'), tests.get_supabase_uid('invited_owner'))$$,
               'Owners should be able to remove owners that arent the primary'
           );

select tests.authenticate_as('invited_owner');

SELECT is(
               (select tenancy.has_role_on_team(get_team_id('test'))),
               false,
               'Should no longer have access to the team'
           );

SELECT *
FROM finish();

ROLLBACK;