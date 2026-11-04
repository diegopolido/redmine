# frozen_string_literal: true

# Deployment-specific tasks (not part of Redmine core).
namespace :deploy do
  desc 'Apply settings that come from ENV (MAILER_FROM -> Setting.mail_from). Run at every boot.'
  task apply_settings: :environment do
    from = ENV['MAILER_FROM'].to_s.strip
    next if from.empty?

    begin
      Mail::Address.new(from)
    rescue Mail::Field::ParseError
      warn "deploy:apply_settings: MAILER_FROM=#{from.inspect} is not a valid address; ignored"
      next
    end

    if Setting.mail_from == from
      puts "==> Setting.mail_from already #{from}"
    else
      Setting.mail_from = from
      puts "==> Setting.mail_from set to #{from} (from MAILER_FROM)"
    end
  end
end
