require "test_helper"

class ConversationRefreshControllerTest < ActiveSupport::TestCase
  setup do
    @source = Rails.root.join("app/javascript/controllers/conversation_refresh_controller.js").read
  end

  test "polling owns one interval and clears it before reconnecting or disconnecting" do
    assert_equal 1, @source.scan(/setInterval\(/).size
    assert_operator @source.index("this.stopPolling()"), :<, @source.index("this.timer = setInterval")

    disconnect_body = @source[/disconnect\(\) \{(?<body>.*?)\n  \}/m, :body]
    assert_includes disconnect_body, "this.stopPolling()"
    assert_includes disconnect_body, "this.abortController?.abort()"
  end

  test "concurrent refreshes and duplicate message ids are ignored" do
    assert_includes @source, "if (this.refreshing) return"
    assert_includes @source, "if (document.getElementById(message.id)) return"
  end
end
