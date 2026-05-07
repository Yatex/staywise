module Billing
  class Plans
    PLAN_DEFINITIONS = [
      { id: "starter", name: "Starter", limit: "1 property", description: "For a single apartment or guest suite." },
      { id: "growth", name: "Growth", limit: "Up to 5 properties", description: "For owners with a small portfolio." },
      { id: "pro", name: "Pro", limit: "Up to 20 properties", description: "For property managers handling more volume." },
      { id: "business", name: "Business", limit: "Custom", description: "For larger operations and custom support." }
    ].freeze

    def self.all
      PLAN_DEFINITIONS
    end

    def self.price_env_for(plan)
      {
        "starter" => "STRIPE_PRICE_STARTER",
        "growth" => "STRIPE_PRICE_GROWTH",
        "pro" => "STRIPE_PRICE_PRO",
        "business" => "STRIPE_PRICE_BUSINESS"
      }.fetch(plan)
    end
  end
end
