module AI
  module SafetyConfig
    module_function

    def safe_router_enabled?
      enabled?("AI_SAFE_ROUTER_ENABLED", default: true)
    end

    def tool_first_flow_enabled?(account: nil, property: nil)
      account_value = account&.ai_automation_settings&.fetch("tool_first_ai_flow", nil)
      return truthy?(account_value) unless account_value.nil?

      property_value = property&.respond_to?(:ai_tool_first_flow) ? property.ai_tool_first_flow : nil
      return truthy?(property_value) unless property_value.nil?

      enabled?("AI_TOOL_FIRST_FLOW_ENABLED", default: true)
    end

    def evidence_required?
      enabled?("AI_EVIDENCE_REQUIRED", default: true)
    end

    def conservative_fallback_enabled?
      enabled?("AI_CONSERVATIVE_FALLBACK_ENABLED", default: true)
    end

    def minimum_reply_confidence
      ENV.fetch("AI_MIN_REPLY_CONFIDENCE", "0.55").to_f
    end

    def answer_confidence_threshold(account: nil)
      account&.ai_answer_confidence_threshold || ENV.fetch("ANSWER_CONFIDENCE_THRESHOLD", "90").to_i
    end

    def enabled?(name, default:)
      value = ENV[name]
      return default if value.blank?

      value.to_s.downcase.in?(%w[1 true yes on])
    end

    def truthy?(value)
      value.to_s.downcase.in?(%w[1 true yes on])
    end
  end
end
