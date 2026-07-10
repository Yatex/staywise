module AI
  module LanguageHelper
    module_function

    def owner_language(account)
      normalize_code(account&.ai_preferred_language).presence || "es"
    end

    def normalize_code(value)
      value.to_s.split(/[-_]/).first.presence
    end
  end
end
