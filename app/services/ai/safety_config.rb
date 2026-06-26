module AI
  module SafetyConfig
    module_function

    def safe_router_enabled?
      enabled?("AI_SAFE_ROUTER_ENABLED", default: true)
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

    def enabled?(name, default:)
      value = ENV[name]
      return default if value.blank?

      value.to_s.downcase.in?(%w[1 true yes on])
    end
  end
end
