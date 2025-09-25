#!/usr/bin/env node

/**
 * Local Database Test Runner with dbdev integration
 * 
 * This script provides a local testing environment that mirrors the CI setup
 * but uses dbdev packages for enhanced testing capabilities.
 */

const { execSync, spawn } = require('child_process');
const { Client } = require('pg');
require('dotenv').config();

// Database connection configuration for local Supabase
const DB_CONFIG = {
  host: 'localhost',
  port: 54322,
  user: 'postgres',
  password: 'postgres',
  database: 'postgres'
};

class LocalTestRunner {
  constructor() {
    this.client = null;
  }

  async connect() {
    this.client = new Client(DB_CONFIG);
    await this.client.connect();
    console.log('✅ Connected to local Supabase database');
  }

  async disconnect() {
    if (this.client) {
      await this.client.end();
      console.log('✅ Disconnected from database');
    }
  }

  async checkSupabaseRunning() {
    try {
      await this.connect();
      await this.disconnect();
      return true;
    } catch (error) {
      return false;
    }
  }

  async startSupabase() {
    console.log('🚀 Starting Supabase local development server...');
    try {
      execSync('supabase db start', { stdio: 'inherit' });
      console.log('✅ Supabase started successfully');
    } catch (error) {
      console.error('❌ Failed to start Supabase:', error.message);
      process.exit(1);
    }
  }

  async resetDatabase() {
    console.log('🔄 Resetting database and applying migrations...');
    try {
      execSync('supabase db reset --yes', { stdio: 'inherit' });
      console.log('✅ Database reset completed');
    } catch (error) {
      console.error('❌ Failed to reset database:', error.message);
      process.exit(1);
    }
  }

  async installDbdevExtensions() {
    console.log('📦 Installing dbdev extensions...');
    
    await this.connect();
    
    try {
      // Install required extensions for dbdev
      await this.client.query(`
        create extension if not exists pgtap with schema extensions;
        create extension if not exists http with schema extensions;
        create extension if not exists pg_tle;
      `);

      // Install dbdev itself
      const dbdevInstallQuery = `
        drop extension if exists "supabase-dbdev";
        select pgtle.uninstall_extension_if_exists('supabase-dbdev');
        select
            pgtle.install_extension(
                'supabase-dbdev',
                resp.contents ->> 'version',
                'PostgreSQL package manager',
                resp.contents ->> 'sql'
            )
        from http(
            (
                'GET',
                'https://api.database.dev/rest/v1/'
                || 'package_versions?select=sql,version'
                || '&package_name=eq.supabase-dbdev'
                || '&order=version.desc'
                || '&limit=1',
                array[
                    (
                        'apiKey',
                        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJp'
                        || 'c3MiOiJzdXBhYmFzZSIsInJlZiI6InhtdXB0cHBsZnZpaWZyY'
                        || 'ndtbXR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2ODAxMDczNzI'
                        || 'sImV4cCI6MTk5NTY4MzM3Mn0.z2CN0mvO2No8wSi46Gw59DFGCTJ'
                        || 'rzM0AQKsu_5k134s'
                    )::http_header
                ],
                null,
                null
            )
        ) x,
        lateral (
            select
                ((row_to_json(x) -> 'content') #>> '{}')::json -> 0
        ) resp(contents);
        
        create extension "supabase-dbdev";
        select dbdev.install('supabase-dbdev');
        drop extension if exists "supabase-dbdev";
        create extension "supabase-dbdev";
      `;

      await this.client.query(dbdevInstallQuery);

      // Install testing helpers
      await this.client.query(`select dbdev.install('basejump-supabase_test_helpers');`);

      console.log('✅ dbdev extensions installed successfully');
    } catch (error) {
      console.error('❌ Failed to install dbdev extensions:', error.message);
      throw error;
    } finally {
      await this.disconnect();
    }
  }

  async runTests() {
    console.log('🧪 Running database tests...');
    
    try {
      execSync('supabase test db', { stdio: 'inherit' });
      console.log('✅ All tests passed!');
    } catch (error) {
      console.error('❌ Tests failed');
      process.exit(1);
    }
  }

  async listAvailablePackages() {
    console.log('📋 Listing available dbdev packages...');
    
    await this.connect();
    
    try {
      const result = await this.client.query(`
        select name, description, version 
        from dbdev.available_packages() 
        order by name;
      `);
      
      console.log('\nAvailable packages:');
      result.rows.forEach(pkg => {
        console.log(`  📦 ${pkg.name} (v${pkg.version}): ${pkg.description}`);
      });
    } catch (error) {
      console.error('❌ Failed to list packages:', error.message);
    } finally {
      await this.disconnect();
    }
  }

  async run() {
    const args = process.argv.slice(2);
    
    try {
      // Check if Supabase is running
      const isRunning = await this.checkSupabaseRunning();
      
      if (!isRunning) {
        await this.startSupabase();
      } else {
        console.log('✅ Supabase is already running');
      }

      // Handle different commands
      if (args.includes('--reset')) {
        await this.resetDatabase();
      }

      if (args.includes('--setup') || args.includes('--install-dbdev')) {
        await this.installDbdevExtensions();
      }

      if (args.includes('--list-packages')) {
        await this.listAvailablePackages();
        return;
      }

      if (!args.includes('--no-test')) {
        await this.runTests();
      }

      console.log('\n🎉 Local testing setup completed successfully!');
      
    } catch (error) {
      console.error('💥 Error during test execution:', error.message);
      process.exit(1);
    }
  }
}

// Handle command line execution
if (require.main === module) {
  const runner = new LocalTestRunner();
  
  // Handle graceful shutdown
  process.on('SIGINT', async () => {
    console.log('\n🛑 Shutting down...');
    await runner.disconnect();
    process.exit(0);
  });

  runner.run().catch(error => {
    console.error('💥 Unhandled error:', error);
    process.exit(1);
  });
}

module.exports = LocalTestRunner;
