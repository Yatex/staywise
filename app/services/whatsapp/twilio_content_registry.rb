require "net/http"
require "json"

module Whatsapp
  class TwilioContentRegistry
    CONTENTS_URL = "https://content.twilio.com/v1/Content".freeze
    LOCK = Mutex.new
    DEFINITIONS = {
      item_actions: {
        "friendly_name" => "ayla_owner_item_actions_v1",
        "language" => "es",
        "types" => {
          "twilio/list-picker" => {
            "body" => "Elegí una opción para continuar.",
            "button" => "Ver opciones",
            "items" => [
              { "item" => "Responder", "id" => "responder", "description" => "Escribir una respuesta al huésped" },
              { "item" => "Siguiente", "id" => "siguiente", "description" => "Ver el siguiente caso pendiente" },
              { "item" => "Omitir", "id" => "omitir", "description" => "Dejar este caso pendiente" },
              { "item" => "Salir", "id" => "salir", "description" => "Cerrar la sesión de revisión" }
            ]
          }
        }
      },
      confirm_reply: {
        "friendly_name" => "ayla_owner_confirm_reply_v1",
        "language" => "es",
        "variables" => { "1" => "Mensaje para el huésped" },
        "types" => {
          "twilio/quick-reply" => {
            "body" => "Vas a enviar al huésped:\n\n“{{1}}”\n\n¿Está correcto?",
            "actions" => [
              { "type" => "QUICK_REPLY", "title" => "Enviar", "id" => "enviar" },
              { "type" => "QUICK_REPLY", "title" => "Editar", "id" => "editar" },
              { "type" => "QUICK_REPLY", "title" => "Cancelar", "id" => "cancelar" }
            ]
          }
        }
      },
      learning: {
        "friendly_name" => "ayla_owner_learning_v1",
        "language" => "es",
        "types" => {
          "twilio/quick-reply" => {
            "body" => "¿Querés que Ayla recuerde esta respuesta para futuras consultas de esta propiedad?",
            "actions" => [
              { "type" => "QUICK_REPLY", "title" => "Sí, recordar", "id" => "recordar" },
              { "type" => "QUICK_REPLY", "title" => "No recordar", "id" => "no_recordar" }
            ]
          }
        }
      },
      checkout_actions: {
        "friendly_name" => "ayla_owner_checkout_actions_v1",
        "language" => "es",
        "types" => {
          "twilio/quick-reply" => {
            "body" => "Elegí una opción para continuar.",
            "actions" => [
              { "type" => "QUICK_REPLY", "title" => "Marcar como visto", "id" => "checkout_visto" },
              { "type" => "QUICK_REPLY", "title" => "Siguiente", "id" => "siguiente" },
              { "type" => "QUICK_REPLY", "title" => "Salir", "id" => "salir" }
            ]
          }
        }
      },
      owner_escalation_notice_with_checkouts: {
        "friendly_name" => "owner_escalation_notice_with_checkouts_v1",
        "language" => "es",
        "variables" => { "1" => "2", "2" => "1", "3" => "1", "4" => "1" },
        "types" => {
          "twilio/quick-reply" => {
            "body" => "Tenés novedades pendientes de tus huéspedes:\n\nPedidos: {{1}}\nConsultas: {{2}}\nAlertas: {{3}}\nCheckouts: {{4}}\n\nSeleccioná qué querés revisar.",
            "actions" => [
              { "type" => "QUICK_REPLY", "title" => "Pedidos", "id" => "pedidos" },
              { "type" => "QUICK_REPLY", "title" => "Consultas", "id" => "consultas" },
              { "type" => "QUICK_REPLY", "title" => "Alertas", "id" => "alertas" },
              { "type" => "QUICK_REPLY", "title" => "Checkouts", "id" => "checkouts" }
            ]
          }
        }
      },
      owner_observer_activity_notice: {
        "friendly_name" => "owner_observer_activity_notice_v2",
        "language" => "es",
        "variables" => {
          "1" => "Hay actividad nueva en una conversación. Huésped: Juan Pérez. Propiedad: Palermo Soho.",
          "2" => "https://aylamanager.com/conversations/123"
        },
        "types" => {
          "twilio/text" => {
            "body" => "{{1}}\n\nAbrir en el panel:\n{{2}}"
          }
        }
      }
    }.freeze

    def self.fetch(key)
      new.fetch(key)
    end

    def self.supports_action?(content_sid, action_id)
      new.supports_action?(content_sid, action_id)
    end

    def initialize(client: nil, cache: Rails.cache)
      @client = client || Client.new
      @cache = cache
    end

    def fetch(key)
      definition = DEFINITIONS.fetch(key.to_sym)
      return unless @client.configured?
      cache_key = cache_key_for(definition)
      return @cache.read(cache_key) if @cache.read(cache_key).present?

      with_creation_lock(definition.fetch("friendly_name")) do
        return @cache.read(cache_key) if @cache.read(cache_key).present?
        content = find_existing(definition) || @client.create_content(definition)
        sid = content.to_h["sid"].presence
        raise "Twilio Content API did not return a ContentSid" if sid.blank?

        @cache.write(cache_key, sid)
        sid
      end
    rescue StandardError => error
      ErrorReporter.report(
        error,
        source: "twilio_content_registry",
        severity: "error",
        context: { content_key: key.to_s, friendly_name: definition&.fetch("friendly_name", nil) }
      )
      nil
    end

    def supports_action?(content_sid, action_id)
      return false if content_sid.blank? || action_id.blank? || !@client.configured?

      cache_key = "ayla/twilio-content-actions/#{@client.account_sid}/#{content_sid}"
      action_ids = @cache.fetch(cache_key, expires_in: 12.hours) do
        content = @client.list_contents.find { |item| item.to_h["sid"] == content_sid }
        content_action_ids(content)
      end
      action_ids.include?(action_id.to_s)
    rescue StandardError => error
      ErrorReporter.report(error, source: "twilio_content_registry", severity: "warning", context: { content_sid: content_sid })
      false
    end

    def provision_and_submit_owner_notice
      sid = fetch(:owner_escalation_notice_with_checkouts)
      raise "Twilio credentials are not configured" if sid.blank?

      approval = @client.fetch_whatsapp_approval(sid)
      approval = @client.submit_whatsapp_approval(
        sid,
        name: "owner_escalation_notice_with_checkouts_v1",
        category: "UTILITY"
      ) if approval.to_h["whatsapp"].blank?

      { "sid" => sid, "approval" => approval }
    end

    def provision_and_submit_observer_notice
      sid = fetch(:owner_observer_activity_notice)
      raise "Twilio credentials are not configured" if sid.blank?

      approval = @client.fetch_whatsapp_approval(sid)
      approval = @client.submit_whatsapp_approval(
        sid,
        name: "owner_observer_activity_notice_v2",
        category: "UTILITY"
      ) if approval.to_h["whatsapp"].blank?

      { "sid" => sid, "approval" => approval }
    end

    private

    def find_existing(definition)
      matches = @client.list_contents.select { |content| content["friendly_name"] == definition.fetch("friendly_name") }
      return if matches.blank?

      expected_type = definition.fetch("types").keys.first
      compatible = matches.find { |content| content.to_h.fetch("types", {}).key?(expected_type) }
      raise "Existing Twilio content #{definition.fetch('friendly_name')} has an incompatible type" unless compatible
      expected_action_ids = content_action_ids(definition)
      if expected_action_ids.present? && content_action_ids(compatible) != expected_action_ids
        raise "Existing Twilio content #{definition.fetch('friendly_name')} has incompatible action IDs"
      end

      compatible
    end

    def cache_key_for(definition)
      "ayla/twilio-content/#{@client.account_sid}/#{definition.fetch('friendly_name')}"
    end

    def content_action_ids(content)
      types = content.to_h.fetch("types", {})
      quick_replies = Array(types.dig("twilio/quick-reply", "actions"))
      list_items = Array(types.dig("twilio/list-picker", "items"))
      (quick_replies + list_items).filter_map { |action| action.to_h["id"].presence }.uniq
    end

    def with_creation_lock(friendly_name, &block)
      LOCK.synchronize do
        if ApplicationRecord.connection.adapter_name.downcase.include?("postgres")
          ApplicationRecord.transaction(requires_new: true) do
            quoted_lock = ApplicationRecord.connection.quote("twilio-content:#{@client.account_sid}:#{friendly_name}")
            ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted_lock}))")
            block.call
          end
        else
          block.call
        end
      end
    end

    class Client
      attr_reader :account_sid

      def initialize(account_sid: ENV["TWILIO_ACCOUNT_SID"], auth_token: ENV["TWILIO_AUTH_TOKEN"])
        @account_sid = account_sid
        @auth_token = auth_token
      end

      def configured?
        account_sid.present? && @auth_token.present?
      end

      def list_contents
        contents = []
        url = "#{CONTENTS_URL}?PageSize=500"
        while url.present?
          response = request(:get, url)
          contents.concat(Array(response["contents"]))
          next_page = response.dig("meta", "next_page_url")
          url = next_page.present? ? URI.join("https://content.twilio.com", next_page).to_s : nil
        end
        contents
      end

      def create_content(definition)
        request(:post, CONTENTS_URL, body: definition)
      end

      def fetch_whatsapp_approval(content_sid)
        request(:get, "#{CONTENTS_URL}/#{content_sid}/ApprovalRequests")
      rescue StandardError => error
        return {} if error.message.include?("status 404")

        raise
      end

      def submit_whatsapp_approval(content_sid, name:, category:)
        request(
          :post,
          "#{CONTENTS_URL}/#{content_sid}/ApprovalRequests/whatsapp",
          body: { "name" => name, "category" => category }
        )
      end

      private

      def request(method, url, body: nil)
        uri = URI(url)
        request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request.basic_auth(account_sid, @auth_token)
        if body
          request["Content-Type"] = "application/json"
          request.body = body.to_json
        end
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
        raise "Twilio Content API failed with status #{response.code}: #{response.body.to_s.first(500)}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    end
  end
end
