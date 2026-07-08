module Billing
  class Plans
    PLAN_DEFINITIONS = [
      { id: "starter", name: "Starter", price: "USD 15/mes", limit: "Hasta 3 propiedades", description: "Para hosts chicos que quieren guía y respuestas automáticas sin complicarse." },
      { id: "growth", name: "Growth", price: "USD 39/mes", limit: "Hasta 10 propiedades", description: "Para co-hosts y administradores chicos que ya manejan varias unidades." },
      { id: "business", name: "Business", price: "USD 59/mes", limit: "Hasta 20 propiedades", description: "Para equipos que administran una cartera en expansión." },
      { id: "scale", name: "Scale", price: "USD 89/mes", limit: "Hasta 35 propiedades", description: "Para operaciones con más volumen de huéspedes y propiedades." },
      { id: "pro", name: "Pro", price: "USD 149/mes", limit: "Hasta 60 propiedades", description: "Para administradores profesionales que necesitan máxima capacidad." }
    ].freeze

    def self.all
      PLAN_DEFINITIONS
    end

    def self.price_env_for(plan)
      effective_price_env_for(plan)
    end

    def self.price_envs_for(plan)
      ["STRIPE_PRICE_#{plan.upcase}"]
    end

    def self.effective_price_env_for(plan)
      price_envs_for(plan).first
    end

    def self.price_id_for(plan)
      ENV[effective_price_env_for(plan)].presence
    end

    def self.plan_for_price_id(price_id)
      return if price_id.blank?

      Subscription::PLANS.find { |plan| price_id_for(plan) == price_id }
    end
  end
end
