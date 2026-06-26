module Billing
  class Plans
    PLAN_DEFINITIONS = [
      { id: "starter", name: "Starter", price: "USD 15/mes", limit: "Hasta 3 propiedades", description: "Para hosts chicos que quieren guía y respuestas automáticas sin complicarse." },
      { id: "growth", name: "Growth", price: "USD 39/mes", limit: "Hasta 10 propiedades", description: "Para co-hosts y administradores chicos que ya manejan varias unidades." },
      { id: "pro", name: "Scale", price: "USD 79/mes", limit: "Hasta 25 propiedades", description: "Para operaciones en crecimiento con más volumen de huéspedes y contenido." },
      { id: "business", name: "Pro", price: "USD 149/mes", limit: "Hasta 50 propiedades", description: "Para administradores profesionales que necesitan más capacidad y soporte." }
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

    def self.plan_for_price_id(price_id)
      return if price_id.blank?

      Subscription::PLANS.find { |plan| ENV[price_env_for(plan)] == price_id }
    end
  end
end
