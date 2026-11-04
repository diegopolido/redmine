#!/usr/bin/env bash
# Converts the old server's MySQL dump into a PostgreSQL dump, locally, with
# throwaway Docker containers. Nothing here touches any server.
#
# Usage:
#   bin/migration/convert_mysql_to_pg.sh <redmine.sql.gz> [output.pgdump]
#
# Steps:
#   1. load the MySQL dump into a temporary mysql:8.0
#   2. read schema_migrations: core version + plugin versions in use
#   3. create the schema in a temporary postgres:18 by running Redmine's OWN
#      migrations (same Redmine version as the old server, from MANIFEST.txt,
#      plus the plugins in plugins/) up to exactly those versions
#   4. copy the data only (bin/migration/mysql_to_pg_copy.rb): booleans,
#      sequences, per-table row-count check
#   5. pg_dump -Fc  →  output (default: next to the input, redmine.pgdump)
#
# The result is still at the OLD schema version; restore.sh migrates it to 7.0.
#
# Env:
#   OLD_REDMINE_VERSION  e.g. 5.0.5 (default: read from MANIFEST.txt next to the dump)
#   KEEP=1               keep the containers (debugging)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <redmine.sql.gz> [output.pgdump]"
DUMP=$(realpath "$1")
[ -f "$DUMP" ] || die "dump not found: $DUMP"
OUT=$(realpath -m "${2:-$(dirname "$DUMP")/redmine.pgdump}")
case "$DUMP" in *.gz) gzip -t "$DUMP" || die "invalid gzip: $DUMP"; CAT="gunzip -c" ;; *) CAT="cat" ;; esac

MANIFEST=$(dirname "$DUMP")/MANIFEST.txt
if [ -z "${OLD_REDMINE_VERSION:-}" ] && [ -f "$MANIFEST" ]; then
  OLD_REDMINE_VERSION=$(awk '/^redmine:/{print $2}' "$MANIFEST")
fi
[ -n "${OLD_REDMINE_VERSION:-}" ] || die "set OLD_REDMINE_VERSION (e.g. 5.0.5) or keep MANIFEST.txt next to the dump."

P=redmine-convert
NET=$P-net
WORK=$ROOT/tmp/migration/convert
cleanup() {
  [ "${KEEP:-}" = 1 ] && return
  docker rm -f $P-mysql $P-pg $P-ruby >/dev/null 2>&1 || true
  docker volume rm $P-mysql-data $P-pg-data >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}
trap cleanup EXIT
KEEP= cleanup
docker network create $NET >/dev/null
mkdir -p "$WORK"

step "1/5 Loading the MySQL dump into a temporary mysql:8.0"
docker run -d --name $P-mysql --network $NET -v $P-mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=convert -e MYSQL_DATABASE=redmine_src mysql:8.0 >/dev/null
for i in $(seq 90); do
  docker exec $P-mysql mysqladmin -h127.0.0.1 -uroot -pconvert ping --silent >/dev/null 2>&1 && break
  [ "$i" = 90 ] && die "MySQL did not start"; sleep 2
done
$CAT "$DUMP" | docker exec -i -e MYSQL_PWD=convert $P-mysql mysql -uroot --default-character-set=utf8mb4 redmine_src
my() { docker exec -e MYSQL_PWD=convert $P-mysql mysql -uroot -N -B redmine_src -e "$1"; }
echo "$(my "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='redmine_src'") tables loaded"

step "2/5 Reading migration versions"
CORE_VERSION=$(my "SELECT MAX(CAST(version AS UNSIGNED)) FROM schema_migrations WHERE version NOT LIKE '%-%'")
mapfile -t PLUGIN_VERSIONS < <(my "SELECT SUBSTRING_INDEX(version,'-',-1) AS p, MAX(CAST(SUBSTRING_INDEX(version,'-',1) AS UNSIGNED)) FROM schema_migrations WHERE version LIKE '%-%' GROUP BY p")
echo "Redmine $OLD_REDMINE_VERSION, core schema $CORE_VERSION"
for pv in "${PLUGIN_VERSIONS[@]}"; do
  name=${pv%%$'\t'*}
  echo "plugin $name, migration ${pv##*$'\t'}"
  [ -d "plugins/$name" ] || die "the dump uses plugin '$name', which is not in plugins/ — add it (or drop its tables on the old server) first."
done

step "3/5 Preparing Redmine $OLD_REDMINE_VERSION (old version) with MySQL + PostgreSQL adapters"
SRC=$WORK/redmine-$OLD_REDMINE_VERSION
docker run --rm -v "$WORK:/w" busybox:stable rm -rf "/w/redmine-$OLD_REDMINE_VERSION"   # may hold root-owned files
mkdir -p "$SRC"
if git fetch -q https://github.com/redmine/redmine "refs/tags/$OLD_REDMINE_VERSION" 2>/dev/null; then
  git archive FETCH_HEAD | tar -x -C "$SRC"
else
  echo "tag $OLD_REDMINE_VERSION not found; using branch ${OLD_REDMINE_VERSION%.*}-stable"
  git fetch -q https://github.com/redmine/redmine "${OLD_REDMINE_VERSION%.*}-stable"
  git archive FETCH_HEAD | tar -x -C "$SRC"
fi
for pv in "${PLUGIN_VERSIONS[@]}"; do cp -r "plugins/${pv%%$'\t'*}" "$SRC/plugins/"; done
# Rails 6.1 (Redmine 5.0) breaks with concurrent-ruby >= 1.3.5
# ("uninitialized constant ActiveSupport::LoggerThreadSafeLevel::Logger"),
# and builder >= 3.3 dropped the blankslate file Redmine 5.0 requires.
printf '%s\n' "gem 'concurrent-ruby', '< 1.3.5'" "gem 'builder', '~> 3.2.4'" > "$SRC/Gemfile.local"
cat > "$SRC/config/database.yml" <<YML
production:
  adapter: postgresql
  database: redmine
  host: $P-pg
  username: redmine
  password: convert
  encoding: utf8
mysql_src:
  adapter: mysql2
  database: redmine_src
  host: $P-mysql
  username: root
  password: convert
  encoding: utf8mb4
YML

docker run -d --name $P-pg --network $NET -v $P-pg-data:/var/lib/postgresql \
  -e POSTGRES_DB=redmine -e POSTGRES_USER=redmine -e POSTGRES_PASSWORD=convert postgres:18 >/dev/null

# Redmine 5.0 supports Ruby <= 3.1. Gems are cached in a volume between runs.
docker run -d --name $P-ruby --network $NET -v "$SRC:/redmine" -v "$ROOT/bin/migration:/scripts:ro" \
  -v redmine-convert-bundle:/usr/local/bundle -w /redmine -e RAILS_ENV=production \
  ruby:3.1-slim sleep infinity >/dev/null
rb() { docker exec $P-ruby bash -euo pipefail -c "$*"; }
rb 'apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential default-libmysqlclient-dev libpq-dev >/dev/null'
rb 'bundle config set --local without "development test" && bundle install -j4 --quiet'
rb 'bundle exec rake generate_secret_token >/dev/null'
for i in $(seq 60); do
  docker exec $P-pg pg_isready -h 127.0.0.1 -U redmine >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "PostgreSQL did not start"; sleep 2
done

step "3/5 Creating the PostgreSQL schema with Redmine's migrations (core $CORE_VERSION)"
count_migrated() { grep -cE "^== .* migrated" || true; }
out=$(rb "bundle exec rake db:migrate VERSION=$CORE_VERSION")
echo "$(count_migrated <<<"$out") core migrations"
for pv in "${PLUGIN_VERSIONS[@]}"; do
  name=${pv%%$'\t'*}; version=${pv##*$'\t'}
  latest=$(ls "$SRC/plugins/$name/db/migrate" | sed -nE 's/^0*([0-9]+)_.*/\1/p' | sort -n | tail -1)
  # Redmine 5.0's redmine:plugins:migrate ignores VERSION=<latest>; only pass
  # VERSION for a partial target. mysql_to_pg_copy.rb verifies schema_migrations.
  if [ "$version" = "$latest" ]; then target=""; else target="VERSION=$version"; fi
  out=$(rb "bundle exec rake redmine:plugins:migrate NAME=$name $target")
  echo "$(count_migrated <<<"$out") $name migrations (target $version of $latest)"
done

step "4/5 Copying data MySQL → PostgreSQL"
rb 'bin/rails runner /scripts/mysql_to_pg_copy.rb'

step "5/5 Writing $OUT"
mkdir -p "$(dirname "$OUT")"
docker exec $P-pg pg_dump -U redmine -Fc --no-owner redmine > "$OUT.part"
mv "$OUT.part" "$OUT"
ls -lh "$OUT" | awk '{print $5, $9}'
sha256sum "$OUT"
step "Done. Next: bin/migration/restore.sh $OUT <redmine-files.tar.gz>"
