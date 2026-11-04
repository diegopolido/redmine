#!/usr/bin/env bash
# Local end-to-end rehearsal of the migration, using only Docker:
#
#   A. "old server": Redmine 5.0-stable + redmine_agile on MySQL 8.0, with
#      sample data (project, issue, attachment, wiki); then runs the real
#      bin/migration/backup_old_server.sh inside it.
#      Skipped if you pass an existing dump + files archive.
#   B. "new server": mysql:8.4 accessory + the production image, wired like
#      config/deploy.yml. Boots on an empty DB (like `kamal setup`), then
#      restores the backup with the same steps as restore.sh and migrates.
#   C. checks: login, Agile board, old attachment downloads, new upload
#      persists across a container re-creation (volume).
#
# Usage:
#   bin/migration/e2e_local_test.sh                      # full rehearsal
#   bin/migration/e2e_local_test.sh dump.sql.gz files.tar.gz   # real backup
# Env: KEEP=1 keeps containers running afterwards (http://localhost:3300).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

P=redmine-e2e                       # prefix for every Docker object
NET=$P-net
IMAGE=$P-app:latest
WORK=$ROOT/tmp/migration/e2e
PORT=3300
ADMIN_PASS='Admin12345!'
SECRET_KEY_BASE=$(openssl rand -hex 64)
ROOT_PW=e2e-root-pw
DB_PW=e2e-db-pw

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32mOK: %s\033[0m\n' "$*"; }

cleanup() {
  docker rm -f $P-old-db $P-old-app $P-db $P-app >/dev/null 2>&1 || true
  docker volume rm $P-old-mysql $P-mysql $P-files >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT
cleanup
mkdir -p "$WORK"
docker network create $NET >/dev/null

wait_mysql() {
  for _ in $(seq 1 90); do
    docker exec "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin -uroot ping --silent' >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "MySQL $1 did not start"
}

# ---------------------------------------------------------------- A. old server
if [ $# -eq 2 ]; then
  DUMP=$(realpath "$1"); FILES_TAR=$(realpath "$2")
  step "A. Using provided backup: $DUMP $FILES_TAR"
else
  step "A. Building an 'old server' (Redmine 5.0-stable + redmine_agile, MySQL 8.0)"
  OLD_SRC=$WORK/redmine-5.0
  docker run --rm -v "$WORK:/w" busybox:stable rm -rf /w/redmine-5.0  # may hold root-owned files
  mkdir -p "$OLD_SRC"
  git fetch -q https://github.com/redmine/redmine 5.0-stable
  git archive FETCH_HEAD | tar -x -C "$OLD_SRC"
  cp -r plugins/redmine_agile "$OLD_SRC/plugins/"
  cat > "$OLD_SRC/config/database.yml" <<YML
production:
  adapter: mysql2
  database: redmine_old
  host: $P-old-db
  username: redmine
  password: "old-pw"
  encoding: utf8mb4
YML

  docker run -d --name $P-old-db --network $NET -v $P-old-mysql:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=old-root -e MYSQL_DATABASE=redmine_old \
    -e MYSQL_USER=redmine -e MYSQL_PASSWORD=old-pw mysql:8.0.39 >/dev/null
  wait_mysql $P-old-db

  docker run -d --name $P-old-app --network $NET -v "$OLD_SRC:/redmine" \
    -v "$ROOT/bin/migration:/scripts:ro" -w /redmine -e RAILS_ENV=production \
    ruby:3.1-slim sleep infinity >/dev/null
  old() { docker exec -e ADMIN_PASS="$ADMIN_PASS" $P-old-app bash -euo pipefail -c "$*"; }
  old 'apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential default-libmysqlclient-dev mariadb-client git >/dev/null'
  old 'bundle config set --local without "development test" && bundle install -j4 --quiet'
  old 'bundle exec rake generate_secret_token db:migrate && REDMINE_LANG=pt-BR bundle exec rake redmine:load_default_data && bundle exec rake redmine:plugins:migrate' | tail -3
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
                      subject: %q(Issue criada no 5.0), priority: IssuePriority.first)
    a = Attachment.new(file: StringIO.new(%q(conteudo do anexo antigo)))
    a.filename = %q(antigo.txt); a.author = admin; a.container = i; a.save!
    page = p.wiki.pages.new(title: %q(Wiki))
    page.content = WikiContent.new(text: %q(h1. Ola do 5.0), author: admin)
    page.save!
    puts %Q(old: Redmine #{Redmine::VERSION}, attachment #{a.id} at #{a.diskfile})
  "'
  step "A. Running bin/migration/backup_old_server.sh inside the old server"
  old 'REDMINE_DIR=/redmine OUT_DIR=/redmine/tmp/backup bash /scripts/backup_old_server.sh'
  docker cp -q $P-old-app:/redmine/tmp/backup/redmine.sql.gz "$WORK/"
  docker cp -q $P-old-app:/redmine/tmp/backup/redmine-files.tar.gz "$WORK/"
  DUMP=$WORK/redmine.sql.gz; FILES_TAR=$WORK/redmine-files.tar.gz
  docker rm -f $P-old-app $P-old-db >/dev/null
fi

# ---------------------------------------------------------------- B. new server
step "B. Building the production image"
docker build -q -t $IMAGE . >/dev/null

step "B. Starting mysql:8.4 accessory (same flags as config/deploy.yml)"
docker run -d --name $P-db --network $NET -v $P-mysql:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=$ROOT_PW -e MYSQL_DATABASE=redmine \
  -e MYSQL_USER=redmine -e MYSQL_PASSWORD=$DB_PW \
  mysql:8.4 --performance-schema=OFF --skip-name-resolve \
  --innodb-buffer-pool-size=256M --max-connections=100 >/dev/null
wait_mysql $P-db

APP_ENV=(-e SECRET_KEY_BASE="$SECRET_KEY_BASE" -e REDMINE_DB_HOST=$P-db
         -e REDMINE_DB_PASSWORD=$DB_PW -e RAILS_MAX_THREADS=3 -e WEB_CONCURRENCY=1)
start_app() {
  docker rm -f $P-app >/dev/null 2>&1 || true
  docker run -d --name $P-app --network $NET -p $PORT:3000 -v $P-files:/rails/files "${APP_ENV[@]}" $IMAGE >/dev/null
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/login)" = 200 ] && return 0
    docker inspect -f '{{.State.Running}}' $P-app | grep -q true || { docker logs --tail 50 $P-app; die "app exited"; }
    sleep 2
  done
  docker logs --tail 50 $P-app; die "app did not answer /login"
}
app_run() { docker run --rm --network $NET -v $P-files:/rails/files "${APP_ENV[@]}" $IMAGE "$@"; }
root_mysql() { docker exec -i $P-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$@"' -- "$@"; }

step "B. First boot on an empty database (like 'kamal setup')"
start_app
ok "fresh install answers /login (healthcheck path)"

step "B. Restore (same steps as restore.sh)"
docker stop $P-app >/dev/null
root_mysql <<SQL
DROP DATABASE IF EXISTS redmine;
CREATE DATABASE redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'%';
SQL
gunzip -c "$DUMP" | root_mysql --default-character-set=utf8mb4 redmine
docker run --rm -v $P-files:/data -v "$(dirname "$FILES_TAR"):/in:ro" busybox:stable sh -euc "
  find /data -mindepth 1 -delete
  tar -xzf /in/$(basename "$FILES_TAR") -C /data
  chown -R 1000:1000 /data
  find /data -type d -exec chmod 755 {} +
  find /data -type f -exec chmod 644 {} +"
app_run bundle exec rake db:migrate redmine:plugins:migrate 2>&1 | tail -5
app_run bin/rails runner bin/migration/post_restore.rb
start_app
ok "migrated app is up"

# ---------------------------------------------------------------- C. checks
step "C. Functional checks"
JAR=$WORK/cookies.txt; rm -f "$JAR"
BASE=http://localhost:$PORT
csrf() { grep -oE 'name="authenticity_token" value="[^"]+"' | head -1 | sed -E 's/.*value="([^"]+)"/\1/'; }

TOKEN=$(curl -s -c "$JAR" -b "$JAR" $BASE/login | csrf)
code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$JAR" -b "$JAR" \
  --data-urlencode "authenticity_token=$TOKEN" --data-urlencode username=admin \
  --data-urlencode "password=$ADMIN_PASS" $BASE/login)
[[ "$code" == 302* && "$code" != *"/login"* ]] || die "login failed ($code)"
curl -s -b "$JAR" $BASE/my/page | grep -q 'class="logout"' || die "not logged in after login"
ok "login works ($code)"

VERSION=$(app_run bin/rails runner 'puts Redmine::VERSION' | tail -1)
[[ "$VERSION" == 7.0* ]] || die "unexpected Redmine version $VERSION"
ok "Redmine $VERSION"

PROJECT=$(app_run bin/rails runner 'puts Project.joins(:enabled_modules).where(enabled_modules: {name: "agile"}).first&.identifier' | tail -1)
[ -n "$PROJECT" ] || die "no project with the agile module"
board=$(curl -s -o "$WORK/board.html" -w '%{http_code}' -b "$JAR" "$BASE/projects/$PROJECT/agile/board")
[ "$board" = 200 ] && grep -q 'agile' "$WORK/board.html" || die "agile board returned $board"
ok "Agile board /projects/$PROJECT/agile/board → 200"

OLD_ATT=$(app_run bin/rails runner 'a = Attachment.first; puts a ? "#{a.id}|#{a.filename}" : ""' | tail -1)
if [ -n "$OLD_ATT" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$BASE/attachments/download/${OLD_ATT%%|*}/${OLD_ATT#*|}")
  [ "$code" = 200 ] || die "old attachment ${OLD_ATT} download returned $code"
  ok "restored attachment ${OLD_ATT#*|} downloads (200)"
fi

# Upload a new attachment through the web UI (issue edit form).
ISSUE=$(app_run bin/rails runner "puts Project.find_by(identifier: '$PROJECT').issues.first&.id" | tail -1)
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

step "C. Re-creating the app container (simulates a new deploy)"
start_app
NEW_ATT=$(app_run bin/rails runner 'a = Attachment.where(filename: "novo.txt").last; puts a ? "#{a.id}|#{a.diskfile}" : ""' | tail -1)
[ -n "$NEW_ATT" ] || die "new attachment not in DB"
curl -s -b "$JAR" $BASE/my/page | grep -q 'class="logout"' || die "session lost after re-deploy (SECRET_KEY_BASE must be fixed)"
ok "session survives a new container (fixed SECRET_KEY_BASE)"
body=$(curl -s -b "$JAR" "$BASE/attachments/download/${NEW_ATT%%|*}/novo.txt")
[ "$body" = "$(cat "$WORK/novo.txt")" ] || die "new attachment content mismatch after re-deploy: '$body'"
docker run --rm -v $P-files:/data busybox:stable stat -c '%u:%g %a %n' "/data${NEW_ATT#*|/rails/files}"
ok "uploaded attachment persisted in the volume across containers (${NEW_ATT#*|})"

step "All checks passed"
if [ "${KEEP:-}" = 1 ]; then echo "Containers kept: http://localhost:$PORT (admin / $ADMIN_PASS). Clean up: docker rm -f $P-db $P-app"; fi
