require "test_helper"

class SecurityConfigurationTest < ActiveSupport::TestCase
  test "cookie sessions use explicit browser protections" do
    options = Rails.application.config.session_options

    assert_equal "_staywise_session", options.fetch(:key)
    assert_equal true, options.fetch(:httponly)
    assert_equal :lax, options.fetch(:same_site)
    assert_equal Rails.env.production?, options.fetch(:secure)
    assert_equal true, options.fetch(:cookie_only)
  end

  test "content security policy denies framing and unsafe object sources" do
    policy = Rails.application.config.content_security_policy

    assert_equal ["'none'"], policy.directives.fetch("frame-ancestors")
    assert_equal ["'none'"], policy.directives.fetch("object-src")
    assert_equal ["'self'"], policy.directives.fetch("default-src")
  end
end
