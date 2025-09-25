/**
  * -------------------------------------------------------
  * Section - Invitations
  * -------------------------------------------------------
 */

/**
 * Invitations are sent to users to join a team
 * They pre-define the role the user should have once they join
 */
create table if not exists tenancy.invitations
(
    -- the id of the invitation
    id                 uuid unique                                              not null default extensions.uuid_generate_v4(),
    -- what role should invitation accepters be given in this account
    team_role          tenancy.team_role                                       not null,
    -- the team the invitation is for
    team_id            uuid references tenancy.teams (id) on delete cascade    not null,
    -- unique token used to accept the invitation
    token              text unique                                              not null default tenancy.generate_token(30),
    -- who created the invitation
    invited_by_user_id uuid references auth.users                               not null,
    -- team name. filled in by a trigger
    team_name          text,
    -- when the invitation was last updated
    updated_at         timestamp with time zone,
    -- when the invitation was created
    created_at         timestamp with time zone,
    -- what type of invitation is this
    invitation_type    tenancy.invitation_type                                 not null,
    primary key (id)
);

-- Open up access to invitations
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE tenancy.invitations TO authenticated, service_role;

-- manage timestamps
CREATE TRIGGER tenancy_set_invitations_timestamp
    BEFORE INSERT OR UPDATE
    ON tenancy.invitations
    FOR EACH ROW
EXECUTE FUNCTION tenancy.trigger_set_timestamps();

/**
  * This funciton fills in account info and inviting user email
  * so that the recipient can get more info about the invitation prior to
  * accepting.  It allows us to avoid complex permissions on accounts
 */
CREATE OR REPLACE FUNCTION tenancy.trigger_set_invitation_details()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.invited_by_user_id = auth.uid();
    NEW.team_name = (select name from tenancy.teams where id = NEW.team_id);
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER tenancy_trigger_set_invitation_details
    BEFORE INSERT
    ON tenancy.invitations
    FOR EACH ROW
EXECUTE FUNCTION tenancy.trigger_set_invitation_details();

-- enable RLS on invitations
alter table tenancy.invitations
    enable row level security;

/**
  * -------------------------
  * Section - RLS Policies
  * -------------------------
 * This is where we define access to tables in the tenancy schema
 */

 create policy "Invitations viewable by team owners" on tenancy.invitations
    for select
    to authenticated
    using (
            created_at > (now() - interval '24 hours')
        and
            tenancy.has_role_on_team(team_id, 'owner') = true
    );


create policy "Invitations can be created by team owners" on tenancy.invitations
    for insert
    to authenticated
    with check (
        -- the inserting user should be an owner of the team
        (tenancy.has_role_on_team(team_id, 'owner') = true)
    );

create policy "Invitations can be deleted by team owners" on tenancy.invitations
    for delete
    to authenticated
    using (
    tenancy.has_role_on_team(team_id, 'owner') = true
    );



/**
  * -------------------------------------------------------
  * Section - Public functions
  * -------------------------------------------------------
  * Each of these functions exists in the public name space because they are accessible
  * via the API.  it is the primary way developers can interact with Basejump accounts
 */


/**
  Returns a list of currently active invitations for a given team
 */

create or replace function public.get_team_invitations(team_id uuid, results_limit integer default 25,
                                                       results_offset integer default 0)
    returns json
    language plpgsql
as
$$
BEGIN
    -- only account owners can access this function
    if (select public.current_user_team_role(get_team_invitations.team_id) ->> 'team_role' <> 'owner') then
        raise exception 'Only team owners can access this function';
    end if;

    return (select json_agg(
                           json_build_object(
                                   'team_role', i.team_role,
                                   'created_at', i.created_at,
                                   'invitation_type', i.invitation_type,
                                   'invitation_id', i.id
                               )
                       )
            from tenancy.invitations i
            where i.team_id = get_team_invitations.team_id
              and i.created_at > now() - interval '24 hours'
            limit coalesce(get_team_invitations.results_limit, 25) offset coalesce(get_team_invitations.results_offset, 0));
END;
$$;

grant execute on function public.get_team_invitations(uuid, integer, integer) to authenticated;


/**
  * Allows a user to accept an existing invitation and join a team
  * This one exists in the public schema because we want it to be called
  * using the supabase rpc method
 */
create or replace function public.accept_invitation(lookup_invitation_token text)
    returns jsonb
    language plpgsql
    security definer set search_path = public, tenancy
as
$$
declare
    lookup_team_id       uuid;
    declare new_member_role tenancy.team_role;
    lookup_team_slug     text;
begin
    select i.team_id, i.team_role, a.slug
    into lookup_team_id, new_member_role, lookup_team_slug
    from tenancy.invitations i
             join tenancy.teams a on a.id = i.team_id
    where i.token = lookup_invitation_token
      and i.created_at > now() - interval '24 hours';

    if lookup_team_id IS NULL then
        raise exception 'Invitation not found';
    end if;

    if lookup_team_id is not null then
        -- we've validated the token is real, so grant the user access
        insert into tenancy.team_user (team_id, user_id, team_role)
        values (lookup_team_id, auth.uid(), new_member_role);
        -- email types of invitations are only good for one usage
        delete from tenancy.invitations where token = lookup_invitation_token and invitation_type = 'one_time';
    end if;
    return json_build_object('team_id', lookup_team_id, 'team_role', new_member_role, 'slug',
                             lookup_team_slug);
EXCEPTION
    WHEN unique_violation THEN
        raise exception 'You are already a member of this account';
end;
$$;

grant execute on function public.accept_invitation(text) to authenticated;


/**
  * Allows a user to lookup an existing invitation and join a team
  * This one exists in the public schema because we want it to be called
  * using the supabase rpc method
 */
create or replace function public.lookup_invitation(lookup_invitation_token text)
    returns json
    language plpgsql
    security definer set search_path = public, tenancy
as
$$
declare
    name              text;
    invitation_active boolean;
begin
    select team_name,
           case when id IS NOT NULL then true else false end as active
    into name, invitation_active
    from tenancy.invitations
    where token = lookup_invitation_token
      and created_at > now() - interval '24 hours'
    limit 1;
    return json_build_object('active', coalesce(invitation_active, false), 'account_name', name);
end;
$$;

grant execute on function public.lookup_invitation(text) to authenticated;


/**
  Allows a user to create a new invitation if they are an owner of a team
 */
create or replace function public.create_invitation(team_id uuid, team_role tenancy.team_role,
                                                    invitation_type tenancy.invitation_type)
    returns json
    language plpgsql
as
$$
declare
    new_invitation tenancy.invitations;
begin
    insert into tenancy.invitations (team_id, team_role, invitation_type, invited_by_user_id)
    values (team_id, team_role, invitation_type, auth.uid())
    returning * into new_invitation;

    return json_build_object('token', new_invitation.token);
end
$$;

grant execute on function public.create_invitation(uuid, tenancy.team_role, tenancy.invitation_type) to authenticated;

/**
  Allows an owner to delete an existing invitation
 */

create or replace function public.delete_invitation(invitation_id uuid)
    returns void
    language plpgsql
as
$$
begin
    -- verify account owner for the invitation
    if tenancy.has_role_on_team(
               (select team_id from tenancy.invitations where id = delete_invitation.invitation_id), 'owner') <>
       true then
        raise exception 'Only team owners can delete invitations';
    end if;

    delete from tenancy.invitations where id = delete_invitation.invitation_id;
end
$$;

grant execute on function public.delete_invitation(uuid) to authenticated;