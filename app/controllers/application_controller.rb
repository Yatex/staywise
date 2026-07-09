class ApplicationController < ActionController::Base
  before_action :set_locale
  before_action :require_authentication
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
    redirect_to login_path unless authenticated?
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

    Rails.logger.info(
      "[request-perf] " \
        "controller=#{controller_name} " \
        "action=#{action_name} " \
        "status=#{response&.status} " \
        "duration_ms=#{duration_ms} " \
        "allocations=#{allocations} " \
        "rss_before_kb=#{rss_before || 'unknown'} " \
        "rss_after_kb=#{rss_after || 'unknown'} " \
        "rss_delta_kb=#{rss_before && rss_after ? rss_after - rss_before : 'unknown'} " \
        "response_bytes=#{response_bytes || 'unknown'} " \
        "sql_queries=#{sql_count} " \
        "records_loaded=#{loaded_records}"
    )
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
