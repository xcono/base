/**
      ____                 _
     |  _ \               (_)
     | |_) | __ _ ___  ___ _ _   _ _ __ ___  _ __
     |  _ < / _` / __|/ _ \ | | | | '_ ` _ \| '_ \
     | |_) | (_| \__ \  __/ | |_| | | | | | | |_) |
     |____/ \__,_|___/\___| |\__,_|_| |_| |_| .__/
                         _/ |               | |
                        |__/                |_|

     Basejump is a starter kit for building SaaS products on top of Supabase.
     Learn more at https://usebasejump.com
 */

/**
  * -------------------------------------------------------
 * Section - Teams
  * -------------------------------------------------------
 */

/**
 * Team roles allow you to provide permission levels to users
 * when they're acting on a team.  By default, we provide
 * "owner" and "member".  The only distinction is that owners can
 * also manage billing and invite/remove team members.
 */
DO
$$
    BEGIN
        -- check if team_role already exists on tenancy schema
        IF NOT EXISTS(SELECT 1
                      FROM pg_type t
                               JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.typname = 'team_role'
                        AND n.nspname = 'tenancy') THEN
            CREATE TYPE tenancy.team_role AS ENUM ('owner', 'member');
        end if;
    end;
$$;

/**
 * Teams are the primary grouping for most objects within
 * the system. They have many users, and all billing is connected to
 * a team.
 */
CREATE TABLE IF NOT EXISTS tenancy.teams
(
    id                    uuid unique                NOT NULL DEFAULT extensions.uuid_generate_v4(),
    -- defaults to the user who creates the team
    -- this user cannot be removed from a team without changing
    -- the primary owner first
    primary_owner_user_id uuid references auth.users not null default auth.uid(),
    -- Team name
    name                  text,
    slug                  text unique,
    updated_at            timestamp with time zone,
    created_at            timestamp with time zone,
    created_by            uuid references auth.users,
    updated_by            uuid references auth.users,
    private_metadata      jsonb                               default '{}'::jsonb,
    public_metadata       jsonb                               default '{}'::jsonb,
    PRIMARY KEY (id)
);


-- Open up access to teams
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE tenancy.teams TO authenticated, service_role;

/**
 * We want to protect some fields on teams from being updated
 * Specifically the primary owner user id and team id.
 * primary_owner_user_id should be updated using the dedicated function
 */
CREATE OR REPLACE FUNCTION tenancy.protect_team_fields()
    RETURNS TRIGGER AS
$$
BEGIN
    IF current_user IN ('authenticated', 'anon') THEN
        -- these are protected fields that users are not allowed to update themselves
        -- platform admins should be VERY careful about updating them as well.
        if NEW.id <> OLD.id
            OR NEW.primary_owner_user_id <> OLD.primary_owner_user_id
        THEN
            RAISE EXCEPTION 'You do not have permission to update this field';
        end if;
    end if;

    RETURN NEW;
END
$$ LANGUAGE plpgsql
SET search_path = '';

-- trigger to protect team fields
CREATE TRIGGER tenancy_protect_team_fields
    BEFORE UPDATE
    ON tenancy.teams
    FOR EACH ROW
EXECUTE FUNCTION tenancy.protect_team_fields();

-- convert any character in the slug that's not a letter, number, or dash to a dash on insert/update for teams
CREATE OR REPLACE FUNCTION tenancy.slugify_team_slug()
    RETURNS TRIGGER AS
$$
BEGIN
    if NEW.slug is not null then
        NEW.slug = lower(regexp_replace(NEW.slug, '[^a-zA-Z0-9-]+', '-', 'g'));
    end if;

    RETURN NEW;
END
$$ LANGUAGE plpgsql
SET search_path = '';

-- trigger to slugify the team slug
CREATE TRIGGER tenancy_slugify_team_slug
    BEFORE INSERT OR UPDATE
    ON tenancy.teams
    FOR EACH ROW
EXECUTE FUNCTION tenancy.slugify_team_slug();

-- enable RLS for teams
alter table tenancy.teams
    enable row level security;

-- protect the timestamps
CREATE TRIGGER tenancy_set_teams_timestamp
    BEFORE INSERT OR UPDATE
    ON tenancy.teams
    FOR EACH ROW
EXECUTE PROCEDURE tenancy.trigger_set_timestamps();

-- set the user tracking
CREATE TRIGGER tenancy_set_teams_user_tracking
    BEFORE INSERT OR UPDATE
    ON tenancy.teams
    FOR EACH ROW
EXECUTE PROCEDURE tenancy.trigger_set_user_tracking();

/**
  * Team users are the users that are associated with a team.
  * They can be invited to join the team, and can have different roles.
  * The system does not enforce any permissions for roles, other than restricting
  * billing and team membership to only owners
 */
create table if not exists tenancy.team_user
(
    -- id of the user in the team
    user_id      uuid references auth.users on delete cascade        not null,
    -- id of the team the user is in
    team_id      uuid references tenancy.teams on delete cascade not null,
    -- role of the user in the team
    team_role    tenancy.team_role                                  not null,
    constraint team_user_pkey primary key (user_id, team_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE tenancy.team_user TO authenticated, service_role;


-- enable RLS for team_user
alter table tenancy.team_user
    enable row level security;

/**
  * When a team gets created, we want to insert the current user as the first
  * owner
 */
create or replace function tenancy.add_current_user_to_new_team()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as
$$
begin
    if new.primary_owner_user_id = auth.uid() then
        insert into tenancy.team_user (team_id, user_id, team_role)
        values (NEW.id, auth.uid(), 'owner');
    end if;
    return NEW;
end;
$$;

-- trigger the function whenever a new team is created
CREATE TRIGGER tenancy_add_current_user_to_new_team
    AFTER INSERT
    ON tenancy.teams
    FOR EACH ROW
EXECUTE FUNCTION tenancy.add_current_user_to_new_team();

/**
  * When a user signs up, we need to create a personal team for them
  * and add them to the team_user table so they can act on it
 */
create or replace function tenancy.run_new_user_setup()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as
$$
declare
    first_account_id    uuid;
    generated_user_name text;
begin

    -- first we setup the user profile
    -- TODO: see if we can get the user's name from the auth.users table once we learn how oauth works
    if new.email IS NOT NULL then
        generated_user_name := split_part(new.email, '@', 1);
    end if;
    -- create the new user's default team
    insert into tenancy.teams (name, primary_owner_user_id, id)
    values (generated_user_name, NEW.id, NEW.id)
    returning id into first_account_id;

    -- add them to the team_user table so they can act on it
    insert into tenancy.team_user (team_id, user_id, team_role)
    values (first_account_id, NEW.id, 'owner');

    return NEW;
end;
$$;

-- trigger the function every time a user is created
create trigger on_auth_user_created
    after insert
    on auth.users
    for each row
execute procedure tenancy.run_new_user_setup();

/**
  * -------------------------------------------------------
 * Section - Team permission utility functions
  * -------------------------------------------------------
  * These functions are stored on the tenancy schema, and useful for things like
  * generating RLS policies
 */

/**
 * Returns true if the current user has the pass in role on the passed in team
 * If no role is sent, will return true if the user is a member of the team
 * NOTE: This is an inefficient function when used on large query sets. You should reach for the get_teams_with_role and lookup
 * the team ID in those cases.
 */
create or replace function tenancy.has_role_on_team(team_id uuid, team_role tenancy.team_role default null)
    returns boolean
    language sql
    security definer
    set search_path = ''
as
$$
select exists(
               select 1
               from tenancy.team_user wu
               where wu.user_id = auth.uid()
                 and wu.team_id = has_role_on_team.team_id
                 and (
                          wu.team_role = has_role_on_team.team_role
                      or has_role_on_team.team_role is null
                   )
           );
$$;

grant execute on function tenancy.has_role_on_team(uuid, tenancy.team_role) to authenticated;


/**
 * Returns team_ids that the current user is a member of. If you pass in a role,
 * it'll only return teams that the user is a member of with that role.
  */
create or replace function tenancy.get_teams_with_role(passed_in_role tenancy.team_role default null)
    returns setof uuid
    language sql
    security definer
    set search_path = ''
as
$$
select team_id
from tenancy.team_user wu
where wu.user_id = auth.uid()
  and (
            wu.team_role = passed_in_role
        or passed_in_role is null
    );
$$;

grant execute on function tenancy.get_teams_with_role(tenancy.team_role) to authenticated;

/**
  * -------------------------
  * Section - RLS Policies
  * -------------------------
  * This is where we define access to tables in the tenancy schema
  */

create policy "users can view their own team_users" on tenancy.team_user
    for select
    to authenticated
    using (
    user_id = auth.uid()
    );

create policy "users can view their teammates" on tenancy.team_user
    for select
    to authenticated
    using (
    tenancy.has_role_on_team(team_id) = true
    );

create policy "Team users can be deleted by owners except primary team owner" on tenancy.team_user
    for delete
    to authenticated
    using (
        (tenancy.has_role_on_team(team_id, 'owner') = true)
        AND
        user_id != (select primary_owner_user_id
                    from tenancy.teams
                    where team_id = teams.id)
    );

create policy "Teams are viewable by members" on tenancy.teams
    for select
    to authenticated
    using (
    tenancy.has_role_on_team(id) = true
    );

-- Primary owner should always have access to the account
create policy "Teams are viewable by primary owner" on tenancy.teams
    for select
    to authenticated
    using (
    primary_owner_user_id = auth.uid()
    );

create policy "Teams can be created by any user" on tenancy.teams
    for insert
    to authenticated
    with check (true);


create policy "Teams can be edited by owners" on tenancy.teams
    for update
    to authenticated
    using (
    tenancy.has_role_on_team(id, 'owner') = true
    );

/**
  * -------------------------------------------------------
  * Section - Public functions
  * -------------------------------------------------------
  * Each of these functions exists in the public name space because they are accessible
  * via the API.  it is the primary way developers can interact with Basejump accounts
 */

/**
* Returns the team_id for a given team slug
*/

create or replace function public.get_team_id(slug text)
    returns uuid
    language sql
    set search_path = ''
as
$$
select id
from tenancy.teams
where slug = get_team_id.slug;
$$;

grant execute on function public.get_team_id(text) to authenticated, service_role;

/**
 * Returns the current user's role within a given team_id
*/
create or replace function public.current_user_team_role(team_id uuid)
    returns jsonb
    language plpgsql
    set search_path = ''
as
$$
DECLARE
    response jsonb;
BEGIN

    select jsonb_build_object(
                   'team_role', wu.team_role,
                   'is_primary_owner', a.primary_owner_user_id = auth.uid()
               )
    into response
    from tenancy.team_user wu
             join tenancy.teams a on a.id = wu.team_id
    where wu.user_id = auth.uid()
      and wu.team_id = current_user_team_role.team_id;

    -- if the user is not a member of the account, throw an error
    if response ->> 'team_role' IS NULL then
        raise exception 'Not found';
    end if;

    return response;
END
$$;

grant execute on function public.current_user_team_role(uuid) to authenticated;

/**
  * Let's you update a users role within a team if you are an owner of that team
  **/
create or replace function public.update_team_user_role(team_id uuid, user_id uuid,
                                                        new_team_role tenancy.team_role,
                                                        make_primary_owner boolean default false)
    returns void
    security definer
    set search_path = ''
    language plpgsql
as
$$
declare
    is_account_owner         boolean;
    is_account_primary_owner boolean;
    changing_primary_owner   boolean;
begin
    -- check if the user is an owner, and if they are, allow them to update the role
    select tenancy.has_role_on_team(update_team_user_role.team_id, 'owner') into is_account_owner;

    if not is_account_owner then
        raise exception 'You must be an owner of the team to update a users role';
    end if;

    -- check if the user being changed is the primary owner, if so its not allowed
    select primary_owner_user_id = auth.uid(), primary_owner_user_id = update_team_user_role.user_id
    into is_account_primary_owner, changing_primary_owner
    from tenancy.teams
    where id = update_team_user_role.team_id;

    if changing_primary_owner = true and is_account_primary_owner = false then
        raise exception 'You must be the primary owner of the team to change the primary owner';
    end if;

    update tenancy.team_user au
    set team_role = new_team_role
    where au.team_id = update_team_user_role.team_id
      and au.user_id = update_team_user_role.user_id;

    if make_primary_owner = true then
        -- first we see if the current user is the owner, only they can do this
        if is_account_primary_owner = false then
            raise exception 'You must be the primary owner of the team to change the primary owner';
        end if;

        update tenancy.teams
        set primary_owner_user_id = update_team_user_role.user_id
        where id = update_team_user_role.team_id;
    end if;
end;
$$;

grant execute on function public.update_team_user_role(uuid, uuid, tenancy.team_role, boolean) to authenticated;

/**
  Returns the current user's teams
 */
create or replace function public.get_teams()
    returns json
    language sql
    set search_path = ''
as
$$
select coalesce(json_agg(
                        json_build_object(
                                'team_id', wu.team_id,
                                'team_role', wu.team_role,
                                'is_primary_owner', a.primary_owner_user_id = auth.uid(),
                                'name', a.name,
                                'slug', a.slug,
                                'created_at', a.created_at,
                                'updated_at', a.updated_at
                            )
                    ), '[]'::json)
from tenancy.team_user wu
         join tenancy.teams a on a.id = wu.team_id
where wu.user_id = auth.uid();
$$;

grant execute on function public.get_teams() to authenticated;

/**
  Returns a specific team that the current user has access to
 */
create or replace function public.get_team(team_id uuid)
    returns json
    language plpgsql
    set search_path = ''
as
$$
BEGIN
    -- check if the user is a member of the team or a service_role user
    if current_user IN ('anon', 'authenticated') and
       (select current_user_team_role(get_team.team_id) ->> 'team_role' IS NULL) then
        raise exception 'You must be a member of a team to access it';
    end if;


    return (select json_build_object(
                           'team_id', a.id,
                           'team_role', wu.team_role,
                           'is_primary_owner', a.primary_owner_user_id = auth.uid(),
                           'name', a.name,
                           'slug', a.slug,
                           'billing_status', bs.status,
                           'created_at', a.created_at,
                           'updated_at', a.updated_at,
                           'metadata', a.public_metadata
                       )
            from tenancy.teams a
                     left join tenancy.team_user wu on a.id = wu.team_id and wu.user_id = auth.uid()
                     join tenancy.config config on true
                     left join (select bs.team_id, status
                                from tenancy.billing_subscriptions bs
                                where bs.team_id = get_team.team_id
                                order by created desc
                                limit 1) bs on bs.team_id = a.id
            where a.id = get_team.team_id);
END;
$$;

grant execute on function public.get_team(uuid) to authenticated, service_role;

/**
  Returns a specific team that the current user has access to
 */
create or replace function public.get_team_by_slug(slug text)
    returns json
    language plpgsql
    set search_path = ''
as
$$
DECLARE
    internal_team_id uuid;
BEGIN
    select a.id
    into internal_team_id
    from tenancy.teams a
    where a.slug IS NOT NULL
      and a.slug = get_team_by_slug.slug;

    return public.get_team(internal_team_id);
END;
$$;

grant execute on function public.get_team_by_slug(text) to authenticated;


/**
  * Create a team
 */
create or replace function public.create_team(slug text default null, name text default null)
    returns json
    language plpgsql
    set search_path = ''
as
$$
DECLARE
    new_team_id uuid;
BEGIN
    insert into tenancy.teams (slug, name)
    values (create_team.slug, create_team.name)
    returning id into new_team_id;

    return public.get_team(new_team_id);
EXCEPTION
    WHEN unique_violation THEN
        raise exception 'A team with that unique ID already exists';
END;
$$;

grant execute on function public.create_team(slug text, name text) to authenticated;

/**
  Update a team with passed in info. None of the info is required except for team ID.
  If you don't pass in a value for a field, it will not be updated.
  If you set replace_meta to true, the metadata will be replaced with the passed in metadata.
  If you set replace_meta to false, the metadata will be merged with the passed in metadata.
 */
create or replace function public.update_team(team_id uuid, slug text default null, name text default null,
                                              public_metadata jsonb default null,
                                              replace_metadata boolean default false)
    returns json
    language plpgsql
    set search_path = ''
as
$$
BEGIN

    -- check if postgres role is service_role
    if current_user IN ('anon', 'authenticated') and
       not (select current_user_team_role(update_team.team_id) ->> 'team_role' = 'owner') then
        raise exception 'Only team owners can update a team';
    end if;

    update tenancy.teams teams
    set slug            = coalesce(update_team.slug, teams.slug),
        name            = coalesce(update_team.name, teams.name),
        public_metadata = case
                              when update_team.public_metadata is null then teams.public_metadata -- do nothing
                              when teams.public_metadata IS NULL then update_team.public_metadata -- set metadata
                              when update_team.replace_metadata
                                  then update_team.public_metadata -- replace metadata
                              else teams.public_metadata || update_team.public_metadata end -- merge metadata
    where teams.id = update_team.team_id;

    return public.get_team(team_id);
END;
$$;

grant execute on function public.update_team(uuid, text, text, jsonb, boolean) to authenticated, service_role;

/**
  Returns a list of current team members. Only team owners can access this function.
  It's a security definer because it requires us to lookup user teams for existing members so we can
  get their names.
 */
create or replace function public.get_team_members(team_id uuid, results_limit integer default 50,
                                                   results_offset integer default 0)
    returns json
    language plpgsql
    security definer
    set search_path = ''
as
$$
BEGIN

    -- only team owners can access this function
    if (select public.current_user_team_role(get_team_members.team_id) ->> 'team_role' <> 'owner') then
        raise exception 'Only team owners can access this function';
    end if;

    return (select json_agg(
                           json_build_object(
                                   'user_id', wu.user_id,
                                   'team_role', wu.team_role,
                                   'name', p.name,
                                   'email', u.email,
                                   'is_primary_owner', a.primary_owner_user_id = wu.user_id
                               )
                       )
            from tenancy.team_user wu
                     join tenancy.teams a on a.id = wu.team_id
                     join tenancy.teams p on p.primary_owner_user_id = wu.user_id and p.id = p.primary_owner_user_id
                     join auth.users u on u.id = wu.user_id
            where wu.team_id = get_team_members.team_id
            limit coalesce(get_team_members.results_limit, 50) offset coalesce(get_team_members.results_offset, 0));
END;
$$;

grant execute on function public.get_team_members(uuid, integer, integer) to authenticated;

/**
  Allows an owner of the team to remove any member other than the primary owner
 */

create or replace function public.remove_team_member(team_id uuid, user_id uuid)
    returns void
    language plpgsql
    set search_path = ''
as
$$
BEGIN
    -- only team owners can access this function
    if tenancy.has_role_on_team(remove_team_member.team_id, 'owner') <> true then
        raise exception 'Only team owners can access this function';
    end if;

    delete
    from tenancy.team_user wu
    where wu.team_id = remove_team_member.team_id
      and wu.user_id = remove_team_member.user_id;
END;
$$;

grant execute on function public.remove_team_member(uuid, uuid) to authenticated;


