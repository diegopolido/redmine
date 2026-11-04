# syntax=docker/dockerfile:1
# Production image for Redmine 7.0 + plugins, deployed with Kamal.
#
#   docker build -t redmine .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=... -e REDMINE_DB_HOST=... redmine
#
# Ruby 4.0.6: Redmine 7.0 supports Ruby 3.2–4.0; 4.0.0–4.0.3 have a wiki
# rendering performance regression, so stay on >= 4.0.4.
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

WORKDIR /rails

# Runtime packages only: MySQL client library (mysql2 adapter) and jemalloc
# (lower memory fragmentation; the server is shared by several apps).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libmariadb3 libjemalloc2 libyaml-0-2 curl && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives

ENV RAILS_ENV="production" \
    RAILS_LOG_TO_STDOUT="1" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test:minimagick" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    REDMINE_ATTACHMENTS_PATH="/rails/files"

# ---------------------------------------------------------------------------
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential default-libmysqlclient-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives

# Everything Redmine's Gemfile reads to decide which gems to install:
# the lockfile, Gemfile.local, database.yml (adapter detection) and the
# plugins' Gemfiles.
COPY Gemfile Gemfile.lock Gemfile.local ./
COPY config/database.yml config/database.yml
COPY plugins/redmine_agile/Gemfile plugins/redmine_agile/Gemfile
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# Precompile assets (core + plugins). No real secret or database is needed.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile && \
    rm -rf tmp/cache/* log/*.log

# ---------------------------------------------------------------------------
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Non-root user; only runtime-writable paths are owned by it.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p files tmp/pdf tmp/thumbnails tmp/cache log public/assets && \
    chown -R rails:rails files tmp log public/assets
USER 1000:1000

# Attachments (mounted as a persistent volume by Kamal).
VOLUME /rails/files

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
