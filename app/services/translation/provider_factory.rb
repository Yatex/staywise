module Translation
  class ProviderFactory
    PROVIDERS = {
      "deepl" => -> { DeepLProvider.new },
      "ai_service" => -> { AIServiceProvider.new }
    }.freeze

    def self.build(name: ENV.fetch("TRANSLATION_PROVIDER", "ai_service"))
      provider_name = name.to_s.strip.downcase
      builder = PROVIDERS[provider_name]
      raise ArgumentError, "Unsupported TRANSLATION_PROVIDER: #{provider_name.presence || "(blank)"}" unless builder

      builder.call
    end
  end
end
