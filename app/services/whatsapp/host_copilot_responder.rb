module Whatsapp
  # This boundary intentionally has no recipient argument. A Copilot response
  # can only return to the verified sender represented by the identity.
  class HostCopilotResponder
    def initialize(identity:, inbound_sender:, provider: ProviderFactory.build)
      @identity = identity
      @sender = HostActor.normalize(inbound_sender)
      @provider = provider
      raise SecurityError, "WhatsApp recipient is not the verified host" unless @sender == identity.phone_number
    end

    def send(body:)
      raise ArgumentError, "El mensaje de respuesta está vacío." if body.blank?

      @provider.send_message(to: @identity.phone_number, body: body)
    end

    def send_sequence(bodies:)
      Array(bodies).map { |body| send(body: body) }
    end
  end
end
