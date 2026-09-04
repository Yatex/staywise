require "test_helper"

class CopilotRuntimeBoundaryTest < ActiveSupport::TestCase
  test "public runtime entrypoints do not reference legacy guest automation or reply delivery" do
    runtime_files = Dir[Rails.root.join("app/controllers/**/*.rb"), Rails.root.join("app/jobs/**/*.rb")]
    forbidden = %w[
      Whatsapp::IncomingMessageHandler
      Whatsapp::OwnerInboundMessageHandler
      Whatsapp::OwnerReplySender
      Whatsapp::HostReplyDelivery
      AI::DecisionService
      OwnerTasks::Creator
      Alerts::Creator
      CheckoutEvents::Creator
      Observer::ActivityRecorder
      Whatsapp::ObserverNotifier
      Whatsapp::OwnerEscalationNotifier
      Notifications::OwnerAlertNotifier
    ]

    violations = runtime_files.filter_map do |path|
      matches = forbidden.select { |constant| File.read(path).include?(constant) }
      "#{path.delete_prefix("#{Rails.root}/")}: #{matches.join(", ")}" if matches.any?
    end

    assert_empty violations, "Legacy automation leaked into a runtime entrypoint:\n#{violations.join("\n")}" 
  end

  test "host Copilot responder exposes no arbitrary recipient argument" do
    parameters = Whatsapp::HostCopilotResponder.instance_method(:send).parameters

    assert_equal [[:keyreq, :body]], parameters
    assert_not_includes parameters, [:keyreq, :to]
  end
end
