#!/usr/bin/env bash
# Local end-to-end rehearsal of the whole migration, using only Docker:
#
#   A. "old server": Redmine 5.0.5 + redmine_agile on MySQL 8.0 with sample data
#      (project, issue, attachment, wiki), then the real backup_old_server.sh.
#      Skipped when you pass a real backup (dump + files archive).
#   B. the real convert_mysql_to_pg.sh  (MySQL dump -> redmine.pgdump)
#   C. "new server": postgres:18 accessory (same limits/tuning as deploy.yml)
#      + the production image. Boots on an empty DB (like `kamal setup`), then
#      restores with the same steps as restore.sh and migrates to 7.0.
#   D. checks: login, Agile board, restored attachment, new upload persists
#      across a container re-creation (volume), session survives re-deploy.
#   E. "moving to another server": backup the new server like backup_now.sh,
#      restore into a third, empty environment, check again.
#
# Usage:
#   bin/migration/e2e_local_test.sh                                   # sample data
#   bin/migration/e2e_local_test.sh redmine.sql.gz redmine-files.tar.gz   # real backup
#     (keep MANIFEST.txt next to the dump; it gives the old Redmine version)
# Env: KEEP=1 keeps the "new server" running afterwards (http://localhost:3300).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

P=redmine-e2e                       # prefix for every Docker object
NET=$P-net
IMAGE=$P-app:latest
WORK=$ROOT/tmp/migration/e2e
OLD_VERSION=5.0.5                   # production runs 5.0.5
ADMIN_PASS='Admin12345!'
SECRET_KEY_BASE=$(openssl rand -hex 64)
DB_PW=e2e-db-pw

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32mOK: %s\033[0m\n' "$*"; }

ENVS=(new move)
cleanup() {
  docker rm -f $P-old-db $P-old-app >/dev/null 2>&1 || true
  for e in "${ENVS[@]}"; do
    docker rm -f $P-$e-db $P-$e-app >/dev/null 2>&1 || true
    docker volume rm $P-$e-pgdata $P-$e-files >/dev/null 2>&1 || true
  done
  docker volume rm $P-old-mysql >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}
trap cleanup EXIT   # with KEEP=1 the end of the script narrows ENVS to keep "new"
cleanup
mkdir -p "$WORK"
docker network create $NET >/dev/null

# ---------------------------------------------------------------- A. old server
if [ $# -eq 2 ]; then
  DUMP=$(realpath "$1"); FILES_TAR=$(realpath "$2")
  step "A. Using provided backup: $DUMP $FILES_TAR"
else
  step "A. Building an 'old server' (Redmine $OLD_VERSION + redmine_agile, MySQL 8.0)"
  OLD_SRC=$WORK/redmine-old
  docker run --rm -v "$WORK:/w" busybox:stable rm -rf /w/redmine-old /w/backup  # may hold root-owned files
  mkdir -p "$OLD_SRC" "$WORK/backup"
  git fetch -q https://github.com/redmine/redmine "refs/tags/$OLD_VERSION"
  git archive FETCH_HEAD | tar -x -C "$OLD_SRC"
  cp -r plugins/redmine_agile "$OLD_SRC/plugins/"
  # Rails 6.1 (Redmine 5.0) breaks with concurrent-ruby >= 1.3.5
  # ("uninitialized constant ActiveSupport::LoggerThreadSafeLevel::Logger"),
# and builder >= 3.3 dropped the blankslate file Redmine 5.0 requires.
  printf '%s\n' "gem 'concurrent-ruby', '< 1.3.5'" "gem 'builder', '~> 3.2.4'" > "$OLD_SRC/Gemfile.local"
  # Same database.yml shape as production (root user, utf8 = utf8mb3).
  cat > "$OLD_SRC/config/database.yml" <<YML
production:
  adapter: mysql2
  database: redmine
  host: $P-old-db
  username: root
  password: "old-root"
  encoding: utf8
YML
  docker run -d --name $P-old-db --network $NET -v $P-old-mysql:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=old-root -e MYSQL_DATABASE=redmine mysql:8.0.39 \
    --character-set-server=utf8mb3 --collation-server=utf8mb3_general_ci >/dev/null
  for i in $(seq 90); do
    docker exec -e MYSQL_PWD=old-root $P-old-db mysqladmin -h127.0.0.1 -uroot ping --silent >/dev/null 2>&1 && break
    [ "$i" = 90 ] && die "old MySQL did not start"; sleep 2
  done

  docker run -d --name $P-old-app --network $NET -v "$OLD_SRC:/redmine" \
    -v "$ROOT/bin/migration:/scripts:ro" -v "$WORK/backup:/backup" -w /redmine -e RAILS_ENV=production \
    -v redmine-convert-bundle:/usr/local/bundle ruby:3.1-slim sleep infinity >/dev/null
  old() { docker exec -e ADMIN_PASS="$ADMIN_PASS" $P-old-app bash -euo pipefail -c "$*"; }
  old 'apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential default-libmysqlclient-dev libpq-dev mariadb-client >/dev/null'
  old 'bundle config set --local without "development test" && bundle install -j4 --quiet'
  old 'bundle exec rake generate_secret_token db:migrate >/dev/null && REDMINE_LANG=pt-BR bundle exec rake redmine:load_default_data >/dev/null && bundle exec rake redmine:plugins:migrate >/dev/null'
  old 'bundle exec rails runner "
    admin = User.find_by_login(%q(admin))
    admin.password = admin.password_confirmation = ENV.fetch(%q(ADMIN_PASS))
    admin.must_change_passwd = false
    admin.save!
    p = Project.create!(name: %q(Migração), identifier: %q(migracao))
    p.trackers = Tracker.all
    p.enabled_module_names = %w(issue_tracking agile wiki files)
    p.save!
    i = Issue.create!(project: p, tracker: p.trackers.first, author: admin,
                      subject: %q(Issue criada no 5.0 — acentuação ç ã é), priority: IssuePriority.first)
    a = Attachment.new(file: StringIO.new(%q(conteudo do anexo antigo)))
    a.filename = %q(antigo.txt); a.author = admin; a.container = i; a.save!
    page = p.wiki.pages.new(title: %q(Wiki))
    page.content = WikiContent.new(text: %q(h1. Olá do 5.0), author: admin)
    page.save!
    puts %Q(old: Redmine #{Redmine::VERSION}, #{Issue.count} issue(s), attachment #{a.id})
  "'
  step "A. Running bin/migration/backup_old_server.sh inside the old server"
  old 'REDMINE_DIR=/redmine OUT_DIR=/backup bash /scripts/backup_old_server.sh' | sed -n '/MANIFEST/,/sha256/p'
  docker run --rm -v "$WORK/backup:/b" busybox:stable chown -R "$(id -u):$(id -g)" /b
  DUMP=$WORK/backup/redmine.sql.gz; FILES_TAR=$WORK/backup/redmine-files.tar.gz
  docker rm -f $P-old-app $P-old-db >/dev/null
fi

# ---------------------------------------------------------------- B. convert
step "B. Converting MySQL -> PostgreSQL (bin/migration/convert_mysql_to_pg.sh)"
PGDUMP=$WORK/redmine.pgdump
rm -f "$PGDUMP"
bin/migration/convert_mysql_to_pg.sh "$DUMP" "$PGDUMP" 2>&1 | grep -vE '^\s+\S+\s+[0-9]+ rows$'
[ "$(head -c 5 "$PGDUMP")" = "PGDMP" ] || die "converter did not produce a pg dump"
ok "converted dump: $(du -h "$PGDUMP" | cut -f1)"

# ---------------------------------------------------------------- helpers
step "Building the production image"
docker build -q -t $IMAGE . >/dev/null

# Same image, cmd and limits as the `db` accessory in config/deploy.yml.
PG_CMD=$(ruby -ryaml -e 'puts YAML.unsafe_load(File.read("config/deploy.yml")).dig("accessories","db","cmd")')
start_db() { # env
  docker run -d --name $P-$1-db --network $NET -v $P-$1-pgdata:/var/lib/postgresql \
    --memory 512m --shm-size 128m \
    -e POSTGRES_DB=redmine -e POSTGRES_USER=redmine -e POSTGRES_PASSWORD=$DB_PW \
    postgres:18 $PG_CMD >/dev/null
  for i in $(seq 60); do
    docker exec $P-$1-db pg_isready -q -h 127.0.0.1 -U redmine && return 0
    [ "$i" = 60 ] && die "PostgreSQL ($1) did not start"; sleep 2
  done
}
app_env() { echo "-e SECRET_KEY_BASE=$SECRET_KEY_BASE -e REDMINE_DB_HOST=$P-$1-db -e REDMINE_DB_PASSWORD=$DB_PW -e RAILS_MAX_THREADS=3 -e WEB_CONCURRENCY=1"; }
start_app() { # env port
  docker rm -f $P-$1-app >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  docker run -d --name $P-$1-app --network $NET -p $2:3000 -v $P-$1-files:/rails/files $(app_env $1) $IMAGE >/dev/null
  for _ in $(seq 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$2/login)" = 200 ] && return 0
    docker inspect -f '{{.State.Running}}' $P-$1-app | grep -q true || { docker logs --tail 40 $P-$1-app; die "app ($1) exited"; }
    sleep 2
  done
  docker logs --tail 40 $P-$1-app; die "app ($1) did not answer /login"
}
# shellcheck disable=SC2046
app_run() { local e=$1; shift; docker run --rm --network $NET -v $P-$e-files:/rails/files $(app_env $e) $IMAGE "$@"; }
psql_() { local e=$1; shift; docker exec -i $P-$e-db psql -v ON_ERROR_STOP=1 -q -U redmine "$@"; }

# Mirrors restore.sh steps 3-8 (without SSH/Kamal).
restore_into() { # env pgdump files.tar.gz port
  docker stop $P-$1-app >/dev/null 2>&1 || true
  psql_ $1 -d postgres <<SQL
DROP DATABASE IF EXISTS redmine WITH (FORCE);
CREATE DATABASE redmine OWNER redmine ENCODING 'UTF8' TEMPLATE template0;
SQL
  docker exec -i $P-$1-db pg_restore -U redmine -d redmine --no-owner --role=redmine --exit-on-error < "$2"
  docker run --rm -v $P-$1-files:/data -v "$(dirname "$3"):/in:ro" busybox:stable sh -euc "
    find /data -mindepth 1 -delete
    tar -xzf /in/$(basename "$3") -C /data
    chown -R 1000:1000 /data
    find /data -type d -exec chmod 755 {} +
    find /data -type f -exec chmod 644 {} +"
  app_run $1 bundle exec rake db:migrate redmine:plugins:migrate 2>&1 | { grep -E "^==.*migrated" || true; } | wc -l | sed 's/$/ migrations applied/'
  app_run $1 bin/rails runner bin/migration/post_restore.rb
  start_app $1 $4
}

JAR=$WORK/cookies.txt
csrf() { grep -oE 'name="authenticity_token" value="[^"]+"' | head -1 | sed -E 's/.*value="([^"]+)"/\1/'; }
login() { # base
  rm -f "$JAR"
  local token code
  token=$(curl -s -c "$JAR" -b "$JAR" $1/login | csrf)
  code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$JAR" -b "$JAR" \
    --data-urlencode "authenticity_token=$token" --data-urlencode username=admin \
    --data-urlencode "password=$ADMIN_PASS" $1/login)
  [[ "$code" == 302* && "$code" != *"/login"* ]] || die "login failed at $1 ($code)"
  curl -s -b "$JAR" $1/my/page | grep -q 'class="logout"' || die "not logged in after login at $1"
}
check_app() { # env base
  login $2; ok "[$1] login works"
  local version project old_att code board
  version=$(app_run $1 bin/rails runner 'puts Redmine::VERSION' | tail -1)
  [[ "$version" == 7.0* ]] || die "[$1] unexpected Redmine version $version"
  ok "[$1] Redmine $version on $(psql_ $1 -d redmine -tA -c 'SHOW server_version')"
  project=$(app_run $1 bin/rails runner 'puts Project.joins(:enabled_modules).where(enabled_modules: {name: "agile"}).first&.identifier' | tail -1)
  [ -n "$project" ] || die "[$1] no project with the agile module"
  board=$(curl -s -o "$WORK/board.html" -w '%{http_code}' -b "$JAR" "$2/projects/$project/agile/board")
  [ "$board" = 200 ] && grep -q 'agile' "$WORK/board.html" || die "[$1] agile board returned $board"
  ok "[$1] Agile board /projects/$project/agile/board → 200"
  old_att=$(app_run $1 bin/rails runner 'a = Attachment.order(:id).first; puts a ? "#{a.id}|#{a.filename}" : ""' | tail -1)
  if [ -n "$old_att" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$2/attachments/download/${old_att%%|*}/${old_att#*|}")
    [ "$code" = 200 ] || die "[$1] attachment ${old_att#*|} download returned $code"
    ok "[$1] attachment ${old_att#*|} downloads (200)"
  fi
  if [ $# -eq 2 ] && [ -z "${REAL_BACKUP:-}" ]; then
    curl -s -b "$JAR" "$2/projects/$project/wiki/Wiki" | grep -q 'Olá do 5.0' || die "[$1] wiki text (UTF-8) not found"
    curl -s -b "$JAR" "$2/projects/$project/issues" | grep -q 'acentuação ç ã é' || die "[$1] issue subject (UTF-8) not found"
    ok "[$1] UTF-8 content intact (wiki + issue subject)"
  fi
}
[ $# -eq 2 ] && REAL_BACKUP=1

# ---------------------------------------------------------------- C. new server
step "C. New server: postgres:18 (512 MB limit, deploy.yml tuning) + production image"
start_db new
start_app new 3300
ok "fresh install answers /login (healthcheck path)"
step "C. Restoring the converted dump (same steps as restore.sh)"
restore_into new "$PGDUMP" "$FILES_TAR" 3300
ok "migrated app is up"

# ---------------------------------------------------------------- D. checks
step "D. Functional checks"
BASE=http://localhost:3300
check_app new $BASE

ISSUE=$(app_run new bin/rails runner "puts Issue.order(:id).first&.id" | tail -1)
[ -n "$ISSUE" ] || die "no issue to attach to"
TOKEN=$(curl -s -b "$JAR" -c "$JAR" "$BASE/issues/$ISSUE" | csrf)
echo "novo anexo $(date +%s)" > "$WORK/novo.txt"
upload=$(curl -s -b "$JAR" -c "$JAR" -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/octet-stream' \
  --data-binary @"$WORK/novo.txt" "$BASE/uploads.js?attachment_id=1&filename=novo.txt&content_type=text%2Fplain")
UP_TOKEN=$(echo "$upload" | grep -oE "[0-9]+\.[0-9a-f]{32,}" | head -1)
[ -n "$UP_TOKEN" ] || die "upload failed: $upload"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -c "$JAR" -X POST \
  --data-urlencode "_method=patch" --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "attachments[1][token]=$UP_TOKEN" --data-urlencode "attachments[1][filename]=novo.txt" \
  "$BASE/issues/$ISSUE")
[ "$code" = 302 ] || die "attaching upload to issue returned $code"

step "D. Re-creating the app container (simulates a new deploy)"
start_app new 3300
curl -s -b "$JAR" $BASE/my/page | grep -q 'class="logout"' || die "session lost after re-deploy (SECRET_KEY_BASE must be fixed)"
ok "session survives a new container (fixed SECRET_KEY_BASE)"
NEW_ATT=$(app_run new bin/rails runner 'a = Attachment.where(filename: "novo.txt").last; puts a ? "#{a.id}|#{a.diskfile}" : ""' | tail -1)
[ -n "$NEW_ATT" ] || die "new attachment not in DB"
body=$(curl -s -b "$JAR" "$BASE/attachments/download/${NEW_ATT%%|*}/novo.txt")
[ "$body" = "$(cat "$WORK/novo.txt")" ] || die "new attachment content mismatch after re-deploy: '$body'"
docker run --rm -v $P-new-files:/data busybox:stable stat -c '%u:%g %a %n' "/data${NEW_ATT#*|/rails/files}"
ok "uploaded attachment persisted in the volume across containers"

# ---------------------------------------------------------------- E. move
step "E. Moving to another server: backup (like bin/backup_now.sh) and restore elsewhere"
MOVE=$WORK/move; rm -rf "$MOVE"; mkdir -p "$MOVE"
docker exec $P-new-db pg_dump -U redmine -Fc --no-owner redmine > "$MOVE/redmine.pgdump"
docker run --rm -v $P-new-files:/data:ro busybox:stable tar -czf - -C /data . > "$MOVE/redmine-files.tar.gz"
start_db move
start_app move 3301
restore_into move "$MOVE/redmine.pgdump" "$MOVE/redmine-files.tar.gz" 3301
check_app move http://localhost:3301
login http://localhost:3301
body=$(curl -s -b "$JAR" "http://localhost:3301/attachments/download/${NEW_ATT%%|*}/novo.txt")
[ "$body" = "$(cat "$WORK/novo.txt")" ] || die "[move] attachment uploaded on the previous server is missing"
for t in issues attachments users projects wiki_pages; do
  a=$(psql_ new -d redmine -tA -c "SELECT count(*) FROM $t"); b=$(psql_ move -d redmine -tA -c "SELECT count(*) FROM $t")
  [ "$a" = "$b" ] || die "[move] $t count differs ($a vs $b)"
done
ok "[move] data and attachments identical on the new server"

step "All checks passed"
if [ "${KEEP:-}" = 1 ]; then
  ENVS=(move)
  echo "Kept: http://localhost:3300 (admin / $ADMIN_PASS). Clean up: docker rm -f $P-new-db $P-new-app"
fi
