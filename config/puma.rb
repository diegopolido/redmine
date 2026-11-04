# frozen_string_literal: true

# Puma configuration for the container image (see Dockerfile).
# Kept deliberately small: the server hosts several apps.
#
#   WEB_CONCURRENCY    number of worker processes (default 1). With 1 Puma
#                      runs in single mode (no cluster master process),
#                      which saves one process worth of memory.
#   RAILS_MAX_THREADS  threads per process (default 3)

threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
threads threads_count, threads_count

workers_count = Integer(ENV.fetch("WEB_CONCURRENCY", 1))
if workers_count > 1
  workers workers_count
  preload_app!
end

port ENV.fetch("PORT", 3000)
environment ENV.fetch("RAILS_ENV", "production")

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
