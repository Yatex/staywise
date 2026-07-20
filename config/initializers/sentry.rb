require Rails.root.join("lib/sentry_event_sanitizer")

if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV.fetch("SENTRY_DSN")
    config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
    config.release = ENV["SENTRY_RELEASE"].presence
    config.traces_sample_rate = Float(ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.0"))
    config.profiles_sample_rate = Float(ENV.fetch("SENTRY_PROFILES_SAMPLE_RATE", "0.0"))
    config.send_default_pii = false
    config.trace_ignore_status_codes = [404]
    config.before_send = lambda do |event, hint|
      SentryEventSanitizer.call(event, hint)
    end
    config.before_breadcrumb = lambda do |breadcrumb, hint|
      SentryEventSanitizer.call_breadcrumb(breadcrumb, hint)
    end
  end
end
