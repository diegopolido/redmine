#!/usr/bin/env bash
# Run ON THE OLD SERVER (Redmine 5.0 + MySQL). Produces, in $OUT_DIR:
#   redmine.sql.gz        mysqldump of the Redmine database (no CREATE DATABASE,
#                         so it restores into any database name)
#   redmine-files.tar.gz  the attachments directory (contents only)
#   MANIFEST.txt          versions, plugin list and sha256 checksums
#
# Usage (copy the script to the old server first):
#   REDMINE_DIR=/var/www/redmine bash backup_old_server.sh
#
# Env:
#   REDMINE_DIR  Redmine root on the old server (default: /var/www/redmine)
#   OUT_DIR      output directory (default: $HOME/redmine-migration)
#   RAILS_ENV    database.yml section to read (default: production)
#
# Idempotent: re-running overwrites the previous backup in $OUT_DIR.
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-/var/www/redmine}"
OUT_DIR="${OUT_DIR:-$HOME/redmine-migration}"
RAILS_ENV="${RAILS_ENV:-production}"

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$REDMINE_DIR/config/database.yml" ] || die "$REDMINE_DIR/config/database.yml not found (set REDMINE_DIR)."
command -v mysqldump >/dev/null || die "mysqldump not found."
command -v ruby >/dev/null      || die "ruby not found (needed to read database.yml)."

# Ruby helper shared by the snippets below (works with Psych 3 and 4).
RUBY_YLOAD='def yload(s) s = ERB.new(s).result; YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(s) : YAML.load(s) end'

step "Reading database settings from $REDMINE_DIR/config/database.yml [$RAILS_ENV]"
# Prints: adapter, database, host, port, username, password (one per line).
mapfile -t DB < <(ruby -ryaml -rerb -e "$RUBY_YLOAD" -e '
  cfg = yload(File.read(ARGV[0]))[ARGV[1]] or abort "no #{ARGV[1]} section"
  puts cfg["adapter"], cfg["database"], (cfg["host"] || "localhost"), (cfg["port"] || 3306),
       cfg["username"], cfg["password"].to_s
' "$REDMINE_DIR/config/database.yml" "$RAILS_ENV")
[[ "${DB[0]}" == mysql2* || "${DB[0]}" == trilogy ]] || die "adapter is '${DB[0]}', expected mysql2."
DB_NAME="${DB[1]}"
echo "database=$DB_NAME host=${DB[2]} user=${DB[4]}"

# Attachments path: configuration.yml (attachments_storage_path) or files/.
FILES_DIR=$(ruby -ryaml -rerb -e "$RUBY_YLOAD" -e '
  f = ARGV[0]; env = ARGV[1]; root = ARGV[2]
  path = nil
  if File.exist?(f)
    y = yload(File.read(f)) || {}
    path = (y[env] || {})["attachments_storage_path"] || (y["default"] || {})["attachments_storage_path"]
  end
  path = File.join(root, "files") if path.to_s.strip.empty?
  puts File.expand_path(path, root)
' "$REDMINE_DIR/config/configuration.yml" "$RAILS_ENV" "$REDMINE_DIR")
[ -d "$FILES_DIR" ] || die "attachments directory $FILES_DIR not found."

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# Credentials via a temporary option file (keeps the password off `ps`).
MYCNF=$(mktemp)
trap 'rm -f "$MYCNF"' EXIT
chmod 600 "$MYCNF"
cat > "$MYCNF" <<CNF
[client]
host=${DB[2]}
port=${DB[3]}
user=${DB[4]}
password="${DB[5]}"
CNF

# --set-gtid-purged exists only in MySQL's mysqldump (not MariaDB's).
GTID_OPT=()
mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged' && GTID_OPT=(--set-gtid-purged=OFF)

step "Dumping database '$DB_NAME' to $OUT_DIR/redmine.sql.gz"
mysqldump --defaults-extra-file="$MYCNF" \
  --single-transaction --quick --hex-blob --triggers \
  --default-character-set=utf8mb4 --no-tablespaces "${GTID_OPT[@]}" \
  "$DB_NAME" | gzip -9 > "$OUT_DIR/redmine.sql.gz.part"
mv "$OUT_DIR/redmine.sql.gz.part" "$OUT_DIR/redmine.sql.gz"

step "Archiving attachments from $FILES_DIR to $OUT_DIR/redmine-files.tar.gz"
tar -czf "$OUT_DIR/redmine-files.tar.gz.part" -C "$FILES_DIR" .
mv "$OUT_DIR/redmine-files.tar.gz.part" "$OUT_DIR/redmine-files.tar.gz"

step "Writing $OUT_DIR/MANIFEST.txt"
{
  echo "date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host:      $(hostname)"
  echo "redmine:   $(grep -E 'MAJOR|MINOR|TINY' "$REDMINE_DIR/lib/redmine/version.rb" | head -3 | awk '{print $3}' | paste -sd.)"
  echo "mysql:     $(mysql --defaults-extra-file="$MYCNF" -N -e 'SELECT VERSION()')"
  echo "database:  $DB_NAME"
  echo "tables:    $(mysql --defaults-extra-file="$MYCNF" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")"
  echo "issues:    $(mysql --defaults-extra-file="$MYCNF" -N -e "SELECT COUNT(*) FROM \`$DB_NAME\`.issues")"
  echo "attachments rows: $(mysql --defaults-extra-file="$MYCNF" -N -e "SELECT COUNT(*) FROM \`$DB_NAME\`.attachments")"
  echo "attachment files: $(find "$FILES_DIR" -type f | wc -l)"
  echo "plugins:"
  for p in "$REDMINE_DIR"/plugins/*/; do
    [ -f "$p/init.rb" ] || continue
    # `version '1.2.3'` or `version SOME_CONSTANT` (resolved from `SOME_CONSTANT = '1.2.3'`).
    v=$(grep -m1 -E "^[[:space:]]*version[[:space:]]" "$p/init.rb" | awk '{print $2}' | tr -d "'\"" || true)
    if [[ "$v" =~ ^[A-Z_]+$ ]]; then
      v=$(grep -m1 -E "^[[:space:]]*$v[[:space:]]*=" "$p/init.rb" | sed -E "s/.*=[[:space:]]*['\"]([^'\"]+).*/\1/")
    fi
    echo "  - $(basename "$p") ${v:-?}"
  done
  echo "sha256:"
  (cd "$OUT_DIR" && sha256sum redmine.sql.gz redmine-files.tar.gz | sed 's/^/  /')
} > "$OUT_DIR/MANIFEST.txt"
cat "$OUT_DIR/MANIFEST.txt"

step "Done. Copy the backup to your machine, e.g.:"
echo "  scp '$(whoami)@$(hostname -f 2>/dev/null || hostname):$OUT_DIR/*' tmp/migration/"
