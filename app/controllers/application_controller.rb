class ApplicationController < ActionController::Base
  PERFORMANCE_WARNING_THRESHOLDS = {
    rss_delta_kb: 20.megabytes / 1.kilobyte,
    allocations: 100_000,
    records_loaded: 500,
    response_bytes: 500.kilobytes,
    duration_ms: 2_000
  }.freeze

  before_action :set_locale
  before_action :require_authentication
  before_action :set_observability_context
  around_action :log_request_performance

  helper_method :current_user, :current_account, :authenticated?

  def default_url_options
    session[:locale].present? ? { locale: I18n.locale } : {}
  end

  private

  def set_locale
    requested_locale = params[:locale].presence
    session[:locale] = requested_locale if requested_locale.in?(I18n.available_locales.map(&:to_s))
    I18n.locale = session[:locale].presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale
  end

  def current_user
    @current_user ||= User.includes(:account).find_by(id: session[:user_id]) if session[:user_id]
  end

  def current_account
    current_user&.account
  end

  def authenticated?
    current_user.present?
  end

  def require_authentication
    return if authenticated?

    session[:return_to_after_login] = request.fullpath if request.get? && request.format.html?
    redirect_to login_path
  end

  def sign_in(user)
    reset_session
    session[:user_id] = user.id
  end

  def sign_out
    reset_session
  end

  def ensure_property_limit!
    return if current_account.can_add_property?

    redirect_to subscription_path, alert: "Tu plan actual alcanzó el límite de propiedades."
  end

  def set_observability_context
    Current.request_id = request.request_id
    Current.account_id = current_account&.id
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.configure_scope do |scope|
      scope.set_tags({
        request_id: request.request_id,
        account_id: current_account&.id,
        controller: controller_name,
        action: action_name
      }.compact)
    end
  end

  def set_sentry_tags(tags)
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.configure_scope { |scope| scope.set_tags(tags.compact) }
  end

  def log_request_performance
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    allocations_before = GC.stat[:total_allocated_objects]
    rss_before = current_rss_kb
    sql_count = 0
    loaded_records = 0

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      next if payload[:name].in?(%w[SCHEMA CACHE])

      sql_count += 1
    end
    instantiation_subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |_name, _started, _finished, _id, payload|
      loaded_records += payload[:record_count].to_i
    end

    yield
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    ActiveSupport::Notifications.unsubscribe(instantiation_subscriber) if instantiation_subscriber

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    allocations = GC.stat[:total_allocated_objects] - allocations_before
    rss_after = current_rss_kb
    response_bytes = response_body_bytes

    metrics = {
      duration_ms: duration_ms,
      allocations: allocations,
      rss_before_kb: rss_before,
      rss_after_kb: rss_after,
      rss_delta_kb: rss_before && rss_after ? rss_after - rss_before : nil,
      response_bytes: response_bytes,
      sql_queries: sql_count,
      records_loaded: loaded_records
    }
    log_line =
      "[request-perf] " \
        "request_id=#{request.request_id} " \
        "controller=#{controller_name} " \
        "action=#{action_name} " \
        "status=#{response&.status} " \
        "#{metrics.map { |key, value| "#{key}=#{value.nil? ? 'unknown' : value}" }.join(' ')}"
    Rails.logger.info(log_line)

    breached = PERFORMANCE_WARNING_THRESHOLDS.filter_map do |metric, threshold|
      value = metrics[metric]
      "#{metric}=#{value}>#{threshold}" if value && value > threshold
    end
    Rails.logger.warn("[request-perf-warning] #{log_line} thresholds=#{breached.join(',')}") if breached.any?
  end

  def current_rss_kb
    status = File.read("/proc/self/status")
    status[/^VmRSS:\s+(\d+)\s+kB$/, 1]&.to_i
  rescue Errno::ENOENT
    nil
  end

  def response_body_bytes
    body = response&.body
    return if body.blank?

    body.respond_to?(:bytesize) ? body.bytesize : body.to_s.bytesize
  rescue StandardError
    nil
  end
end
