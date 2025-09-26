# Supabase Database Testing with dbdev - Local Setup Guide

This guide explains how to set up and use Supabase database tests locally with [dbdev](https://github.com/supabase/dbdev), the PostgreSQL package manager.

## 🚀 Quick Start

1. **Install Dependencies**
   ```bash
   npm install
   ```

2. **Start Local Development**
   ```bash
   npm run test:db:local --setup
   ```

3. **Run Tests**
   ```bash
   npm run test:db
   ```

## 📦 What is dbdev?

`dbdev` is Supabase's PostgreSQL package manager that allows you to:
- Install PostgreSQL extensions and packages directly in your database
- Manage dependencies for your database schema
- Share reusable database code across projects
- Access a growing ecosystem of database packages

## 🏗️ Current Setup

Your project is already configured with:

### Database Extensions
- **pgtap**: PostgreSQL testing framework
- **http**: HTTP client for PostgreSQL
- **pg_tle**: Trusted Language Extensions for PostgreSQL
- **supabase-dbdev**: The dbdev package manager itself

### Testing Packages
- **basejump-supabase_test_helpers**: Testing utilities for Supabase multi-tenant applications

## 🛠️ Local Development Setup

### Prerequisites

1. **Supabase CLI** installed and configured
2. **Node.js** (v18 or higher)
3. **PostgreSQL** running locally via Supabase

### Installation Steps

1. **Clone and Setup**
   ```bash
   git clone <your-repo>
   cd supabase
   npm install
   ```

2. **Start Supabase Local Environment**
   ```bash
   # Option 1: Manual setup
   supabase db start
   supabase db reset --yes
   
   # Option 2: Using npm script
   npm run dev:setup
   ```

3. **Install dbdev Extensions**
   ```bash
   # Install all required packages
   npm run dbdev:install
   
   # Or run the full test setup
   npm run test:db:local --setup
   ```

## 📋 Available Commands

### NPM Scripts

- `npm run test:db` - Run standard Supabase database tests
- `npm run test:db:local` - Run tests with local dbdev setup
- `npm run dev:setup` - Start Supabase and reset database
- `npm run db:reset` - Reset database and apply migrations
- `npm run dbdev:install` - Install dbdev packages

### Local Test Runner Options

```bash
# Full setup and test run
npm run test:db:local --setup

# Reset database before testing
npm run test:db:local --reset

# Just install dbdev packages
npm run test:db:local --install-dbdev

# List available packages
npm run test:db:local --list-packages

# Setup without running tests
npm run test:db:local --setup --no-test
```

### Package Management

```bash
# List installed packages
node scripts/install-dbdev-packages.js --list

# Search for packages
node scripts/install-dbdev-packages.js --search "test"

# Install a specific package
node scripts/install-dbdev-packages.js --install "package-name"

# Uninstall a package
node scripts/install-dbdev-packages.js --uninstall "package-name"
```

## 🧪 Testing Workflow

### 1. Standard Development Workflow

```bash
# Start development environment
npm run dev:setup

# Make changes to migrations or tests
# ...

# Run tests
npm run test:db
```

### 2. Advanced Testing with dbdev

```bash
# Full setup with dbdev packages
npm run test:db:local --setup

# Install additional testing packages as needed
node scripts/install-dbdev-packages.js --install "new-testing-package"

# Run tests
npm run test:db
```

### 3. CI/CD Integration

Your GitHub Actions workflow (`.github/workflows/tests.yaml`) already:
- Installs dbdev during the test setup
- Installs required testing packages
- Runs the full test suite

## 📊 Database Configuration

### Local Database Connection

The local Supabase instance runs on:
- **Host**: localhost
- **Port**: 54322
- **User**: postgres
- **Password**: postgres
- **Database**: postgres

### Environment Variables

Create a `.env` file (copy from `.env.example`):

```bash
# Database Configuration
SUPABASE_DB_HOST=localhost
SUPABASE_DB_PORT=54322
SUPABASE_DB_USER=postgres
SUPABASE_DB_PASSWORD=postgres
SUPABASE_DB_NAME=postgres

# Supabase API
SUPABASE_API_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=<your-anon-key>
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
```

## 🔧 Troubleshooting

### Common Issues

1. **Supabase not running**
   ```bash
   # Check if Supabase is running
   supabase db start
   
   # If issues persist, reset
   supabase db stop
   supabase db start
   ```

2. **dbdev installation fails**
   ```bash
   # Ensure HTTP extension is available
   # Check if your PostgreSQL instance supports pg_tle
   npm run test:db:local --setup
   ```

3. **Tests fail after setup**
   ```bash
   # Reset and try again
   npm run db:reset
   npm run dbdev:install
   npm run test:db
   ```

### Debug Mode

Enable detailed logging:

```bash
DEBUG=true npm run test:db:local
```

## 📚 Available dbdev Packages

### Currently Installed

- **basejump-supabase_test_helpers**: Testing utilities for multi-tenant Supabase applications
  - Functions for creating test users
  - Authentication helpers
  - RLS testing utilities

### Explore More Packages

```bash
# Search the dbdev registry
npm run test:db:local --list-packages

# Or use the package manager directly
node scripts/install-dbdev-packages.js --search "test"
node scripts/install-dbdev-packages.js --search "auth"
node scripts/install-dbdev-packages.js --search "uuid"
```

## 🔗 Useful Resources

- [dbdev GitHub Repository](https://github.com/supabase/dbdev)
- [dbdev Package Registry](https://database.dev)
- [Supabase Local Development](https://supabase.com/docs/guides/local-development)
- [pgTAP Testing Framework](https://pgtap.org/)
- [Basejump Multi-Tenant Framework](https://github.com/usebasejump/basejump)

## 🤝 Contributing

When adding new database functionality:

1. Write tests in `supabase/tests/database/`
2. Use appropriate dbdev packages for testing utilities
3. Update this documentation if adding new packages
4. Ensure tests pass both locally and in CI

## 📝 Example Test Structure

```sql
-- Example test file: supabase/tests/database/99-my-feature.sql
BEGIN;
create extension "basejump-supabase_test_helpers" version '0.0.6';

select plan(5);

-- Setup test data
select tests.create_supabase_user('test_user');
select tests.authenticate_as('test_user');

-- Your tests here
select ok(
    my_function() is not null,
    'My function should return a value'
);

-- Clean up and finish
select tests.clear_authentication();
SELECT * FROM finish();
ROLLBACK;
```

This setup provides a robust, scalable testing environment that mirrors your production setup while leveraging the power of dbdev for enhanced testing capabilities.
