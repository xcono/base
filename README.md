# Supabase Multi-Tenant SaaS System

A robust, secure multi-tenant SaaS system built on Supabase with comprehensive team management, invitation system, and billing integration.

Based on [Basejump](https://github.com/usebasejump/basejump).
Uses 3rd-party extension `select dbdev.install('basejump-supabase_test_helpers');` for testing.

## 🏗️ Architecture Overview

This system implements a **team-based multi-tenancy** model where:
- Each user automatically gets a personal team upon signup
- Users can create additional teams and invite others
- Teams have owners and members with different permission levels
- All data is isolated by team membership through Row Level Security (RLS)

## 📊 Database Schema

### Core Tables

#### `tenancy.teams`
The central entity representing organizations/teams in the system.

**Key Fields:**
- `id` (UUID): Primary key, defaults to `uuid_generate_v4()`
- `primary_owner_user_id` (UUID): References `auth.users`, cannot be removed
- `name` (TEXT): Display name for the team
- `slug` (TEXT): URL-friendly identifier, auto-sanitized
- `private_metadata` (JSONB): Internal team data
- `public_metadata` (JSONB): Public team information
- `created_at`, `updated_at`: Automatic timestamps
- `created_by`, `updated_by`: User tracking

**Security Features:**
- Protected fields (`id`, `primary_owner_user_id`) cannot be updated by users
- Automatic slug sanitization (alphanumeric + dashes only)
- RLS policies restrict access to team members only

#### `tenancy.team_user`
Junction table linking users to teams with specific roles.

**Key Fields:**
- `user_id` (UUID): References `auth.users`
- `team_id` (UUID): References `tenancy.teams`
- `team_role` (ENUM): `'owner'` or `'member'`
- Composite primary key: `(user_id, team_id)`

**Security Features:**
- Cascade deletes when user or team is deleted
- RLS policies prevent unauthorized access
- Primary owner cannot be removed from team

#### `tenancy.invitations`
Manages team invitation system with token-based security.

**Key Fields:**
- `id` (UUID): Primary key
- `team_id` (UUID): References `tenancy.teams`
- `team_role` (ENUM): Role to assign upon acceptance
- `token` (TEXT): Unique invitation token (30 chars, URL-safe)
- `invitation_type` (ENUM): `'one_time'` or `'24_hour'`
- `invited_by_user_id` (UUID): Creator of invitation
- `team_name` (TEXT): Cached for display purposes

**Security Features:**
- Tokens expire after 24 hours
- One-time invitations are deleted after use
- Only team owners can create/manage invitations
- Secure token generation using `gen_random_bytes()`

#### `tenancy.billing_customers` & `tenancy.billing_subscriptions`
Integration with external billing providers (Stripe, etc.).

**Security Features:**
- Service role only for write operations
- Team members can view their own billing data
- Comprehensive subscription status tracking

### Enums

```sql
-- Team roles define permission levels
CREATE TYPE tenancy.team_role AS ENUM ('owner', 'member');

-- Invitation types control usage patterns
CREATE TYPE tenancy.invitation_type AS ENUM ('one_time', '24_hour');

-- Subscription statuses for billing integration
CREATE TYPE tenancy.subscription_status AS ENUM (
    'trialing', 'active', 'canceled', 'incomplete',
    'incomplete_expired', 'past_due', 'unpaid'
);
```

## 🔐 Security Architecture

### Row Level Security (RLS) Policies

All tables have RLS enabled with comprehensive policies:

#### Team Access Control
```sql
-- Teams are viewable by members
CREATE POLICY "Teams are viewable by members" ON tenancy.teams
    FOR SELECT TO authenticated
    USING (tenancy.has_role_on_team(id) = true);

-- Primary owner always has access
CREATE POLICY "Teams are viewable by primary owner" ON tenancy.teams
    FOR SELECT TO authenticated
    USING (primary_owner_user_id = auth.uid());

-- Only owners can edit teams
CREATE POLICY "Teams can be edited by owners" ON tenancy.teams
    FOR UPDATE TO authenticated
    USING (tenancy.has_role_on_team(id, 'owner') = true);
```

#### Team User Management
```sql
-- Users can view their own team memberships
CREATE POLICY "users can view their own team_users" ON tenancy.team_user
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- Users can view teammates
CREATE POLICY "users can view their teammates" ON tenancy.team_user
    FOR SELECT TO authenticated
    USING (tenancy.has_role_on_team(team_id) = true);

-- Owners can remove members (except primary owner)
CREATE POLICY "Team users can be deleted by owners except primary team owner" ON tenancy.team_user
    FOR DELETE TO authenticated
    USING (
        (tenancy.has_role_on_team(team_id, 'owner') = true)
        AND user_id != (SELECT primary_owner_user_id FROM tenancy.teams WHERE team_id = teams.id)
    );
```

#### Invitation Security
```sql
-- Only team owners can view/create/delete invitations
CREATE POLICY "Invitations viewable by team owners" ON tenancy.invitations
    FOR SELECT TO authenticated
    USING (
        created_at > (now() - interval '24 hours')
        AND tenancy.has_role_on_team(team_id, 'owner') = true
    );
```

### Security Definer Functions

Critical functions use `SECURITY DEFINER` for controlled privilege escalation:

#### Permission Checking
```sql
-- Efficient team membership checking
CREATE FUNCTION tenancy.has_role_on_team(team_id uuid, team_role tenancy.team_role DEFAULT null)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = public;
```

#### User Setup Automation
```sql
-- Automatic personal team creation on user signup
CREATE FUNCTION tenancy.run_new_user_setup()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public;
```

#### Invitation Processing
```sql
-- Secure invitation acceptance
CREATE FUNCTION public.accept_invitation(lookup_invitation_token text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, tenancy;
```

### Security Best Practices Implemented

1. **Principle of Least Privilege**: Functions only have necessary permissions
2. **Defense in Depth**: Multiple layers of security (RLS, function permissions, triggers)
3. **Input Validation**: Automatic sanitization of slugs and tokens
4. **Audit Trail**: Complete tracking of who created/modified what
5. **Token Security**: Cryptographically secure random tokens
6. **Expiration Handling**: Automatic cleanup of expired invitations
7. **Protected Fields**: Critical fields cannot be modified by users

## 👥 User Roles & Permissions

### Team Roles

#### Owner
- **Can**: Create/edit teams, manage members, create invitations, access billing
- **Cannot**: Remove primary owner, modify protected team fields
- **Scope**: Full team management capabilities

#### Member
- **Can**: View team data, accept invitations
- **Cannot**: Manage team settings, invite others, access billing
- **Scope**: Read-only team access

### Permission Matrix

| Action | Owner | Member | Non-Member | Anonymous |
|--------|-------|--------|------------|-----------|
| View team | ✅ | ✅ | ❌ | ❌ |
| Edit team | ✅ | ❌ | ❌ | ❌ |
| Create team | ✅ | ✅ | ✅ | ❌ |
| Invite members | ✅ | ❌ | ❌ | ❌ |
| Remove members | ✅* | ❌ | ❌ | ❌ |
| Access billing | ✅ | ❌ | ❌ | ❌ |
| Accept invitations | ✅ | ✅ | ✅ | ❌ |

*Except primary owner

## 🔄 Business Logic Flows

### User Onboarding
1. **User signs up** → `auth.users` record created
2. **Trigger fires** → `tenancy.run_new_user_setup()` executes
3. **Personal team created** → Team with `id = user_id` and `primary_owner_user_id = user_id`
4. **Team membership added** → User added to `team_user` as owner
5. **User can immediately** → Access their personal team, create additional teams

### Team Creation
1. **User calls** → `public.create_team(slug, name)`
2. **Team inserted** → `tenancy.teams` record created
3. **Trigger fires** → `tenancy.add_current_user_to_new_team()` executes
4. **Membership added** → Creator becomes team owner
5. **RLS policies** → Ensure only team members can access

### Invitation Flow
1. **Owner creates invitation** → `public.create_invitation(team_id, role, type)`
2. **Token generated** → Secure 30-character token created
3. **Invitation stored** → Record in `tenancy.invitations` with 24-hour expiry
4. **Recipient looks up** → `public.lookup_invitation(token)` returns team info
5. **Recipient accepts** → `public.accept_invitation(token)` adds to team
6. **Cleanup** → One-time invitations deleted, 24-hour invitations remain

### Member Management
1. **Owner removes member** → `public.remove_team_member(team_id, user_id)`
2. **Validation** → Ensures user is team owner, not removing primary owner
3. **Deletion** → Removes `team_user` record
4. **Access revoked** → User immediately loses team access via RLS

## 🛡️ Security Audit Results

### ✅ Strengths

1. **Comprehensive RLS**: All tables properly protected with granular policies
2. **Secure Token Generation**: Uses `gen_random_bytes()` for invitation tokens
3. **Automatic Cleanup**: Expired invitations handled by time-based policies
4. **Protected Fields**: Critical fields cannot be modified by users
5. **Audit Trail**: Complete tracking of all modifications
6. **Input Sanitization**: Automatic slug cleaning and validation
7. **Principle of Least Privilege**: Functions have minimal necessary permissions
8. **Defense in Depth**: Multiple security layers (RLS, triggers, function permissions)

### ⚠️ Areas for Enhancement

1. **Rate Limiting**: No built-in rate limiting for invitation creation
2. **Audit Logging**: Could benefit from detailed audit logs for compliance
3. **MFA Integration**: No multi-factor authentication requirements
4. **Session Management**: Relies on Supabase's default session handling
5. **Data Encryption**: Uses Supabase's default encryption (AES-256 at rest)

### 🔒 Security Recommendations

1. **Implement Rate Limiting**: Add rate limiting for invitation creation
2. **Enhanced Audit Logging**: Consider adding detailed audit logs
3. **MFA Requirements**: Consider requiring MFA for sensitive operations
4. **Regular Security Reviews**: Schedule periodic security assessments
5. **Monitor Anomalies**: Implement monitoring for unusual access patterns

## 🚀 API Functions

### Team Management
- `public.create_team(slug, name)` - Create new team
- `public.update_team(team_id, slug, name, metadata, replace_metadata)` - Update team
- `public.get_team(team_id)` - Get team details
- `public.get_team_by_slug(slug)` - Get team by slug
- `public.get_teams()` - Get user's teams
- `public.get_team_members(team_id, limit, offset)` - List team members

### Member Management
- `public.current_user_team_role(team_id)` - Get user's role in team
- `public.update_team_user_role(team_id, user_id, role, make_primary)` - Update member role
- `public.remove_team_member(team_id, user_id)` - Remove team member

### Invitation System
- `public.create_invitation(team_id, role, type)` - Create invitation
- `public.get_team_invitations(team_id, limit, offset)` - List invitations
- `public.delete_invitation(invitation_id)` - Delete invitation
- `public.lookup_invitation(token)` - Lookup invitation details
- `public.accept_invitation(token)` - Accept invitation

### Billing Integration
- `public.get_team_billing_status(team_id)` - Get billing status
- `public.service_role_upsert_customer_subscription(team_id, customer, subscription)` - Update billing data

## 🧪 Testing

The system includes comprehensive test coverage:

- **Schema Tests**: Verify all tables, functions, and policies exist
- **Team Account Tests**: Test team creation, management, and permissions
- **Invitation Tests**: Test invitation creation, acceptance, and expiration
- **Member Management Tests**: Test adding/removing team members
- **Role Tests**: Test different permission levels
- **Security Tests**: Verify RLS policies work correctly

## 📈 Performance Considerations

1. **Indexes**: Consider adding indexes on frequently queried columns
2. **Function Optimization**: `tenancy.has_role_on_team()` noted as inefficient for large datasets
3. **Pagination**: All list functions support pagination
4. **Caching**: Consider caching team membership for frequently accessed data

## 🔧 Configuration

The system uses `tenancy.config` for configuration:
- `service_name`: Currently set to 'supabase'
- Extensible for additional configuration options

## 📝 Migration Strategy

The system uses Supabase's migration system:
1. All changes go through migration files
2. Migrations are versioned with timestamps
3. Rollback procedures documented
4. Schema changes are declarative

---

This system provides a robust, secure foundation for multi-tenant SaaS applications with comprehensive team management, invitation systems, and billing integration. The security architecture follows industry best practices with defense in depth, principle of least privilege, and comprehensive audit trails.
