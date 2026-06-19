#!/bin/bash
set -e

# Update packages
apt-get update
apt-get install -y postgresql-14 postgresql-client-14

# Enable and start PostgreSQL
systemctl enable postgresql
systemctl start postgresql

# Create labuser and database
sudo -u postgres psql -c "CREATE USER labuser WITH PASSWORD 'Lab@2024!';"
sudo -u postgres psql -c "CREATE DATABASE labdb OWNER labuser;"

# Configure PostgreSQL to listen on private IP
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '10.0.2.10';"
sudo -u postgres psql -c "ALTER SYSTEM SET max_connections = '20';"

# Add host-based authentication for app subnet
echo 'host labdb labuser 10.0.1.0/24 md5' >> /etc/postgresql/14/main/pg_hba.conf

# Restart PostgreSQL to apply changes
systemctl restart postgresql
