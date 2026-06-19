module Billing
  class Plans
    PLAN_DEFINITIONS = [
      { id: "starter", name: "Inicial", limit: "1 propiedad", description: "Para un apartamento o unidad de huéspedes." },
      { id: "growth", name: "Crecimiento", limit: "Hasta 5 propiedades", description: "Para propietarios con un portafolio chico." },
      { id: "pro", name: "Pro", limit: "Hasta 20 propiedades", description: "Para administradores con más volumen." },
      { id: "business", name: "Empresa", limit: "Personalizado", description: "Para operaciones grandes y soporte a medida." }
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
