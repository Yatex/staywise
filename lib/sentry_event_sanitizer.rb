require "uri"

class SentryEventSanitizer
  FILTERED = "[FILTERED]".freeze
  SENSITIVE_KEY = /
    authorization|token|secret|password|passw|wifi|code|key|lockbox|
    decision_context|prompt|message|body|content|evidence|reservation|
    phone|guest_name|tool_response
  /ix
  SCANNER_PATH = %r{
    /(wp-admin|wp-login|wordpress|phpmyadmin|\.env|sitemap\.xml)(?:/|$)
  }ix

  def self.call(event, _hint = nil)
    return if scanner_event?(event)

    event.user = {}
    event.extra = sanitize(event.extra)
    event.contexts = sanitize(event.contexts)
    if event.request
      event.request.data = nil
      event.request.cookies = nil
      event.request.query_string = nil
      event.request.headers = event.request.headers.to_h.slice("X-Request-Id", "Content-Type")
    end
    event
  end

  def self.call_breadcrumb(breadcrumb, _hint = nil)
    return if breadcrumb.category.to_s.start_with?("console")

    breadcrumb.data = sanitize(breadcrumb.data)
    breadcrumb.message = sanitize_text(breadcrumb.message)
    breadcrumb
  end

  def self.sanitize(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key] = key.to_s.match?(SENSITIVE_KEY) ? FILTERED : sanitize(item)
      end
    when Array
      value.first(50).map { |item| sanitize(item) }
    when String
      sanitize_text(value)
    else
      value
    end
  end

  def self.sanitize_text(value)
    value.to_s
      .gsub(/(authorization|token|secret|password|passw|wifi|code|lockbox|phone)\s*[:=]\s*[^\s,;]+/i, "\\1=#{FILTERED}")
      .first(500)
  end

  def self.scanner_event?(event)
    path = URI.parse(event.request&.url.to_s).path
    path.match?(SCANNER_PATH)
  rescue URI::InvalidURIError
    false
  end
end
