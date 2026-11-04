#!/usr/bin/env bash
# Creates .env.production (git- and docker-ignored) from .env.production.example, filling in fresh
# random values for SECRET_KEY_BASE and the MySQL passwords.
# Idempotent: never overwrites an existing .env.production.
#
# Usage: bin/migration/init_secrets.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE=.env.production

if [ -e "$ENV_FILE" ]; then
  echo "OK: $ENV_FILE already exists — leaving it untouched."
  exit 0
fi
git check-ignore -q "$ENV_FILE" || { echo "ERROR: $ENV_FILE is not git-ignored; refusing to create it." >&2; exit 1; }

umask 077
sed -e "s/^SECRET_KEY_BASE=$/SECRET_KEY_BASE=$(openssl rand -hex 64)/" \
    -e "s/^MYSQL_ROOT_PASSWORD=$/MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/^REDMINE_DB_PASSWORD=$/REDMINE_DB_PASSWORD=$(openssl rand -hex 24)/" \
    .env.production.example > "$ENV_FILE"

echo "Created $ENV_FILE (mode 600) with random SECRET_KEY_BASE and MySQL passwords."
echo "Next: fill in KAMAL_REGISTRY_PASSWORD, SMTP_USERNAME and SMTP_PASSWORD, then back the file up."
