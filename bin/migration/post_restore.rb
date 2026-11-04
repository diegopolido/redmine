# frozen_string_literal: true

# Run after restoring a database from the old server:
#   bin/rails runner bin/migration/post_restore.rb
# Clears the Rails cache and invalidates every session/autologin token
# created on the old server. Idempotent.

Rails.cache.clear
deleted = Token.where(action: %w[session autologin]).delete_all
puts "Cache cleared; #{deleted} session/autologin tokens removed."
puts "Redmine #{Redmine::VERSION}, schema #{ActiveRecord::Base.connection_pool.migration_context.current_version}"
Redmine::Plugin.all.each { |p| puts "  plugin #{p.id} #{p.version}" }
