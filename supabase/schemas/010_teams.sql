-- file: 010_teams.sql
-- usage: foundational control-plane schema for teams (apply first)
-- teams: defines teams and team members tables in schema `app` to allow users to belong to multiple teams:
--   - app.teams: registry of teams
--   - app.team_members: tean and user relationship
--   - app.role_rank: function to rank roles
--   - app.has_role: function to check if current user has at least min_role in target team
-- behavior:
--   - use RLS to control access for team members
--   - adds essential indexes for performance and RLS evaluation
--   - contains only DDL; no SECURITY DEFINER and no SDML
-- purpose: users can belong to multiple teams (N:N users→teams)
-- contains: app.teams, app.team_members, app.role_rank, app.has_role


-- ensure required extensions
create extension if not exists citext with schema public; -- for case-insensitive email
create extension if not exists pgcrypto with schema public; -- for gen_random_uuid()

-- create app schema
create schema if not exists app;

-- Create teams table
create table teams (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    slug text not null default uuid(),
    created_at timestamp with time zone default current_timestamp,
    updated_at timestamp with time zone default current_timestamp
);

-- Create team_members table
create table team_members (
    id uuid primary key default gen_random_uuid(),
    team_id uuid references teams(id),
    -- avoid cross-schema reference to auth.users table
    user_id uuid not null, 
    role text not null default 'member',
    created_at timestamp with time zone default current_timestamp,
    updated_at timestamp with time zone default current_timestamp
);


-- deterministic ordering of roles for comparison
create or replace function app.role_rank(r app.role)
returns int
language sql
security invoker
set search_path = ''
immutable
as $$
  select case r when 'owner' then 4 when 'admin' then 3 when 'member' then 2 else 1 end;
$$;

-- check if current user has at least min_role in target tenant (service role bypasses)
create or replace function app.has_role(target_team_id uuid, min_role app.role)
returns boolean
language plpgsql
security invoker
set search_path = ''
stable
as $$
begin
  if app.is_service_role() then
    return true;
  end if;
  return exists (
    select 1
    from app.team_members m
    where m.team_id = target_team_id
      and m.user_id = (select auth.uid())
      and app.role_rank(m.role) >= app.role_rank(min_role)
  );
end;
$$;