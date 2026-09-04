module Whatsapp
  class HostCopilotHandler
    TECHNICAL_ERROR_MESSAGE = "Tuve un problema técnico intentando preparar la respuesta. Probá nuevamente en unos minutos.".freeze

    def initialize(parsed:, identity:, provider: ProviderFactory.build, client: Copilot::AIClient.new)
      @parsed = parsed
      @identity = identity
      @provider = provider
      @client = client
      @responder = HostCopilotResponder.new(identity: identity, inbound_sender: parsed.from, provider: provider)
    end

    def call
      report_guest_collision if @identity.collision_with_guest?
      @session, created = current_or_new_session
      return duplicate_result if duplicate_message?

      remember_inbound!
      return handle_command if command.present?
      return start_session if created

      case @session.state
      when "awaiting_property" then select_property
      when "awaiting_guest_message", "active_thread" then prepare_draft
      else reset_to_property_selection
      end
    end

    private

    def current_or_new_session
      session = HostWhatsappCopilotSession.find_by(participant_phone: @identity.phone_number)
      if session && (session.expired? || session.account_id != @identity.account.id || session.user_id != @identity.user.id)
        session.destroy!
        session = nil
      end
      return [session, false] if session

      created = HostWhatsappCopilotSession.create!(
        account: @identity.account,
        user: @identity.user,
        co_host: @identity.co_host,
        participant_phone: @identity.phone_number,
        actor_role: @identity.role,
        state: "awaiting_property",
        last_activity_at: Time.current
      )
      [created, true]
    rescue ActiveRecord::RecordNotUnique
      [HostWhatsappCopilotSession.find_by!(participant_phone: @identity.phone_number), false]
    end

    def duplicate_message?
      inbound_sid.present? && @session.last_inbound_message_sid == inbound_sid
    end

    def remember_inbound!
      @session.update!(last_activity_at: Time.current, last_inbound_message_sid: inbound_sid)
    end

    def start_session
      properties = available_properties.to_a
      return deliver("No tenés propiedades habilitadas para consultar en Ayla.") if properties.empty?

      if properties.one?
        activate_property!(properties.first)
        deliver("Perfecto. Estamos consultando sobre #{properties.first.display_name}.\n\nMandame ahora el mensaje que recibiste del huésped.")
      else
        deliver(property_prompt(properties))
      end
    end

    def select_property
      matches = property_matches(@parsed.body)
      return deliver("No encontré esa propiedad entre las que tenés habilitadas.\n\n#{property_prompt(available_properties.to_a)}") if matches.empty?
      return deliver("Encontré más de una propiedad:\n\n#{numbered_properties(matches)}\n\n¿Cuál es?") if matches.many?

      activate_property!(matches.first)
      deliver("Listo, #{matches.first.display_name}.\n\nMandame el mensaje del huésped tal como te llegó.")
    end

    def prepare_draft
      property = selected_property
      return reset_to_property_selection unless property

      thread = current_thread || create_thread!(property)
      result = Copilot::DraftService.call(
        thread: thread,
        content: @parsed.body,
        source: "whatsapp",
        channel_metadata: inbound_metadata,
        client: @client
      )
      @session.update!(state: "active_thread", copilot_thread: thread, last_activity_at: Time.current)

      if result.success?
        deliver_sequence(draft_messages(result.run), run: result.run)
      else
        deliver(TECHNICAL_ERROR_MESSAGE, run: result.run, processing_error: result.run&.error_type || result.error&.class&.name)
      end
    rescue StandardError => error
      ErrorReporter.report(error, source: "host_whatsapp_copilot", severity: "error", context: inbound_metadata)
      deliver(TECHNICAL_ERROR_MESSAGE, processing_error: error.class.name)
    end

    def handle_command
      case command
      when :cancel
        result = deliver("Consulta cancelada. Escribime cuando quieras empezar otra.")
        @session.destroy!
        result
      when :property
        name = selected_property&.display_name
        deliver(name ? "La propiedad seleccionada es #{name}." : property_prompt(available_properties.to_a))
      when :change_property
        @session.update!(selected_property: nil, copilot_thread: nil, state: "awaiting_property")
        deliver(property_prompt(available_properties.to_a))
      when :new_consultation
        return deliver("Primero elegí una propiedad.\n\n#{property_prompt(available_properties.to_a)}") unless selected_property

        thread = create_thread!(selected_property)
        @session.update!(copilot_thread: thread, state: "awaiting_guest_message")
        deliver("Nueva consulta sobre #{selected_property.display_name}.\n\nMandame el mensaje que recibiste del huésped.")
      end
    end

    def command
      normalized = @parsed.body.to_s.parameterize(separator: " ").squish
      {
        "cancelar" => :cancel,
        "propiedad" => :property,
        "cambiar propiedad" => :change_property,
        "nueva consulta" => :new_consultation
      }[normalized]
    end

    def activate_property!(property)
      raise ActiveRecord::RecordNotFound unless available_properties.where(id: property.id).exists?

      thread = create_thread!(property)
      @session.update!(selected_property: property, copilot_thread: thread, state: "awaiting_guest_message")
    end

    def create_thread!(property)
      @identity.user.copilot_threads.create!(account: @identity.account, property: property, source: "whatsapp")
    end

    def current_thread
      thread = @session.copilot_thread
      return unless thread
      return unless thread.account_id == @identity.account.id && thread.user_id == @identity.user.id
      return unless thread.property_id == @session.selected_property_id

      thread
    end

    def selected_property
      property = @session.selected_property
      property if property && available_properties.where(id: property.id).exists?
    end

    def available_properties
      @identity.available_properties.order(:name, :id)
    end

    def property_matches(input)
      value = input.to_s.strip
      properties = available_properties.to_a
      if value.match?(/\A\d+\z/)
        selected = properties[value.to_i - 1]
        return selected ? [selected] : []
      end

      needle = value.parameterize
      exact = properties.select { |property| property.display_name.parameterize == needle }
      return exact if exact.any?

      properties.select { |property| property.display_name.parameterize.include?(needle) || needle.include?(property.display_name.parameterize) }
    end

    def reset_to_property_selection
      @session.update!(selected_property: nil, copilot_thread: nil, state: "awaiting_property")
      deliver(property_prompt(available_properties.to_a))
    end

    def property_prompt(properties)
      return "No tenés propiedades habilitadas para consultar en Ayla." if properties.empty?

      "¿Sobre qué propiedad querés consultar?\n\n#{numbered_properties(properties)}\n\nRespondé con el número o nombre de la propiedad."
    end

    def numbered_properties(properties)
      properties.each_with_index.map { |property, index| "#{index + 1}. #{property.display_name}" }.join("\n")
    end

    def draft_messages(run)
      owner_message = format_owner_summary(run)
      copyable_message = run.missing_information? ? run.clarifying_question_guest : run.guest_reply

      [owner_message, copyable_message.presence].compact
    end

    def format_owner_summary(run)
      language = language_name(run.detected_language)
      if run.missing_information?
        parts = [
          "No tengo información suficiente para responder esto con seguridad.",
          "El huésped pregunta:\n#{normalized_guest_question(run.guest_question_es)}",
          "Me falta:\n#{run.clarifying_question_es}"
        ]
        parts << "Idioma: #{language}"
        return parts.join("\n\n")
      end

      [
        "El huésped pregunta:\n#{normalized_guest_question(run.guest_question_es)}",
        "Respuesta:\n#{normalized_answer_summary(run.answer_summary_es)}",
        "Idioma: #{language}"
      ].join("\n\n")
    end

    def normalized_guest_question(value)
      value.to_s.sub(/\A(?:el\s+hu[eé]sped\s+pregunta(?:\s+que)?|pregunta)\s*:?\s*/i, "").presence || value
    end

    def normalized_answer_summary(value)
      value.to_s.sub(/\A(?:la\s+respuesta\s+(?:es|indica)|respuesta)\s*:?\s*/i, "").presence || value
    end

    def language_name(code)
      { "es" => "Español", "en" => "Inglés", "pt" => "Portugués", "fr" => "Francés", "it" => "Italiano", "de" => "Alemán" }.fetch(code.to_s.downcase, code.to_s.upcase)
    end

    def deliver(body, run: nil, processing_error: nil)
      deliver_sequence([body], run: run, processing_error: processing_error)
    end

    def deliver_sequence(bodies, run: nil, processing_error: nil)
      deliveries = @responder.send_sequence(bodies: bodies)
      message_metadata = deliveries.zip(bodies).map do |delivery, body|
        delivery_metadata(delivery, body: body, processing_error: processing_error)
      end
      success = deliveries.all? { |delivery| delivery.respond_to?(:success?) ? delivery.success? : delivery == true }
      metadata = aggregate_delivery_metadata(message_metadata, success: success, processing_error: processing_error)
      @session.update!(last_activity_at: Time.current, delivery_metadata: metadata) if @session.persisted?
      record_run_delivery(run, metadata) if run
      last_delivery = deliveries.last
      {
        conversation: nil,
        copilot_thread: @session.copilot_thread,
        replied: success,
        ignored: false,
        channel: "host",
        error: success ? nil : "host_whatsapp_delivery_failed",
        provider_message_id: last_delivery.respond_to?(:provider_message_id) ? last_delivery.provider_message_id : nil
      }.compact
    end

    def aggregate_delivery_metadata(messages, success:, processing_error:)
      last = messages.last || {}
      {
        "recipient_role" => @identity.role,
        "recipient_phone" => @identity.phone_number,
        "message_count" => messages.size,
        "messages" => messages,
        "success" => success,
        "provider_message_id" => last["provider_message_id"],
        "provider_status" => last["provider_status"],
        "delivery_error" => messages.filter_map { |item| item["delivery_error"] }.first,
        "processing_error" => processing_error,
        "sent_at" => Time.current.iso8601
      }.compact
    end

    def delivery_metadata(delivery, body:, processing_error:)
      success = delivery.respond_to?(:success?) ? delivery.success? : delivery == true
      {
        "recipient_role" => @identity.role,
        "recipient_phone" => @identity.phone_number,
        "response_length" => body.length,
        "success" => success,
        "provider_message_id" => (delivery.provider_message_id if delivery.respond_to?(:provider_message_id)),
        "provider_status" => (delivery.provider_status if delivery.respond_to?(:provider_status)),
        "delivery_error" => (delivery.error if delivery.respond_to?(:error)),
        "processing_error" => processing_error,
        "sent_at" => Time.current.iso8601
      }.compact
    end

    def record_run_delivery(run, metadata)
      run.update!(channel_metadata: run.channel_metadata.merge("whatsapp_delivery" => metadata))
      trace = run.ai_decision_log
      return unless trace

      trace.update!(payload: trace.payload.to_h.merge("whatsapp_delivery" => AIDecisionLog.sanitize_trace(metadata)))
    end

    def inbound_metadata
      {
        source: "whatsapp",
        inbound_host_user_id: @identity.user.id,
        account_id: @identity.account.id,
        property_id: @session.selected_property_id,
        host_actor_role: @identity.role,
        co_host_id: @identity.co_host&.id,
        session_id: @session.id,
        inbound_message_sid: inbound_sid
      }.compact
    end

    def inbound_sid
      @inbound_sid ||= @parsed.metadata.to_h["MessageSid"].presence || @parsed.metadata.to_h["SmsMessageSid"].presence
    end

    def report_guest_collision
      Rails.logger.warn("[host-whatsapp-copilot] host_guest_phone_collision role=#{@identity.role} account_id=#{@identity.account.id}")
      ErrorReporter.report(
        source: "host_whatsapp_copilot",
        severity: "warning",
        message: "Verified host phone also exists as a guest phone",
        context: { account_id: @identity.account.id, host_role: @identity.role }
      )
    end

    def duplicate_result
      {
        conversation: nil,
        copilot_thread: @session.copilot_thread,
        replied: false,
        ignored: true,
        duplicate: true,
        channel: "host"
      }
    end
  end
end
