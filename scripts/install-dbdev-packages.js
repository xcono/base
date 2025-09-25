#!/usr/bin/env node

/**
 * dbdev Package Installation Script
 * 
 * This script installs and manages dbdev packages for the local development environment.
 */

const { Client } = require('pg');
require('dotenv').config();

const DB_CONFIG = {
  host: 'localhost',
  port: 54322,
  user: 'postgres',
  password: 'postgres',
  database: 'postgres'
};

// List of packages to install for this project
const REQUIRED_PACKAGES = [
  'basejump-supabase_test_helpers',
  // Add more packages as needed for your project
];

class DbdevPackageManager {
  constructor() {
    this.client = null;
  }

  async connect() {
    this.client = new Client(DB_CONFIG);
    await this.client.connect();
  }

  async disconnect() {
    if (this.client) {
      await this.client.end();
    }
  }

  async installPackage(packageName, version = null) {
    console.log(`📦 Installing package: ${packageName}${version ? ` (v${version})` : ''}`);
    
    try {
      const query = version 
        ? `select dbdev.install('${packageName}', '${version}');`
        : `select dbdev.install('${packageName}');`;
        
      await this.client.query(query);
      console.log(`✅ Successfully installed ${packageName}`);
    } catch (error) {
      console.error(`❌ Failed to install ${packageName}:`, error.message);
      throw error;
    }
  }

  async uninstallPackage(packageName) {
    console.log(`🗑️  Uninstalling package: ${packageName}`);
    
    try {
      await this.client.query(`select dbdev.uninstall('${packageName}');`);
      console.log(`✅ Successfully uninstalled ${packageName}`);
    } catch (error) {
      console.error(`❌ Failed to uninstall ${packageName}:`, error.message);
    }
  }

  async listInstalledPackages() {
    console.log('📋 Listing installed packages...');
    
    try {
      const result = await this.client.query(`
        select name, version, description 
        from dbdev.installed_packages() 
        order by name;
      `);
      
      if (result.rows.length === 0) {
        console.log('  No packages installed');
        return [];
      }

      console.log('\nInstalled packages:');
      result.rows.forEach(pkg => {
        console.log(`  📦 ${pkg.name} (v${pkg.version}): ${pkg.description}`);
      });
      
      return result.rows;
    } catch (error) {
      console.error('❌ Failed to list installed packages:', error.message);
      return [];
    }
  }

  async searchPackages(searchTerm) {
    console.log(`🔍 Searching for packages containing: ${searchTerm}`);
    
    try {
      const result = await this.client.query(`
        select name, description, version 
        from dbdev.available_packages() 
        where name ilike $1 or description ilike $1
        order by name;
      `, [`%${searchTerm}%`]);
      
      if (result.rows.length === 0) {
        console.log('  No packages found');
        return [];
      }

      console.log('\nFound packages:');
      result.rows.forEach(pkg => {
        console.log(`  📦 ${pkg.name} (v${pkg.version}): ${pkg.description}`);
      });
      
      return result.rows;
    } catch (error) {
      console.error('❌ Failed to search packages:', error.message);
      return [];
    }
  }

  async installRequiredPackages() {
    console.log('🚀 Installing required packages for this project...');
    
    for (const packageName of REQUIRED_PACKAGES) {
      try {
        await this.installPackage(packageName);
      } catch (error) {
        console.warn(`⚠️  Could not install ${packageName}, continuing...`);
      }
    }
  }

  async run() {
    const args = process.argv.slice(2);
    
    try {
      await this.connect();
      console.log('✅ Connected to database');

      if (args.includes('--list') || args.includes('-l')) {
        await this.listInstalledPackages();
        return;
      }

      if (args.includes('--search') || args.includes('-s')) {
        const searchIndex = args.findIndex(arg => arg === '--search' || arg === '-s');
        const searchTerm = args[searchIndex + 1];
        if (!searchTerm) {
          console.error('❌ Please provide a search term');
          process.exit(1);
        }
        await this.searchPackages(searchTerm);
        return;
      }

      if (args.includes('--install') || args.includes('-i')) {
        const installIndex = args.findIndex(arg => arg === '--install' || arg === '-i');
        const packageName = args[installIndex + 1];
        const version = args[installIndex + 2];
        
        if (!packageName) {
          console.error('❌ Please provide a package name');
          process.exit(1);
        }
        
        await this.installPackage(packageName, version);
        return;
      }

      if (args.includes('--uninstall') || args.includes('-u')) {
        const uninstallIndex = args.findIndex(arg => arg === '--uninstall' || arg === '-u');
        const packageName = args[uninstallIndex + 1];
        
        if (!packageName) {
          console.error('❌ Please provide a package name');
          process.exit(1);
        }
        
        await this.uninstallPackage(packageName);
        return;
      }

      // Default action: install required packages
      await this.installRequiredPackages();
      
    } catch (error) {
      console.error('💥 Error:', error.message);
      process.exit(1);
    } finally {
      await this.disconnect();
    }
  }
}

// Handle command line execution
if (require.main === module) {
  const manager = new DbdevPackageManager();
  
  manager.run().catch(error => {
    console.error('💥 Unhandled error:', error);
    process.exit(1);
  });
}

module.exports = DbdevPackageManager;
