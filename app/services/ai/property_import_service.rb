require "json"
require "net/http"

module AI
  class PropertyImportService
    PROPERTY_ATTRIBUTES = %w[
      name
      address
      internal_nickname
      check_in_time
      checkout_time
      wifi_name
      wifi_password
      house_rules
      access_instructions
      parking_instructions
      emergency_information
      owner_contact_instructions
      ai_general_notes
      tag_list
    ].freeze

    Result = Struct.new(:property_attributes, :faqs, :source_summary, keyword_init: true) do
      def useful?
        property_attributes.values.any?(&:present?) || faqs.any?
      end
    end

    class ImportError < StandardError; end

    def self.call(account:, property:, upload:)
      new(account: account, property: property, upload: upload).call
    end

    def initialize(account:, property:, upload:)
      @account = account
      @property = property
      @upload = upload
    end

    def call
      raise ImportError, "El servicio de IA no está configurado para leer archivos." if ENV["AI_SERVICE_URL"].blank?

      document = Properties::UploadTextExtractor.new(@upload).call
      result = remote_import(document)
      raise ImportError, "No pude extraer campos útiles del archivo. Probá con una imagen más clara o un documento con más texto." unless result.useful?

      result
    rescue Properties::UploadTextExtractor::ExtractionError => error
      raise ImportError, error.message
    rescue ImportError
      raise
    rescue JSON::ParserError
      raise ImportError, "La IA respondió con un formato inválido. Probá de nuevo."
    rescue StandardError => error
      report_error(error)
      raise ImportError, "No pude leer el archivo con IA en este momento. Probá de nuevo en unos minutos."
    end

    private

    def remote_import(document)
      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/property_import")
      response = Net::HTTP.post(
        uri,
        payload_for(document).to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )

      unless response.is_a?(Net::HTTPSuccess)
        raise ImportError, "La IA no pudo procesar el archivo. Estado #{response.code}."
      end

      normalize_response(JSON.parse(response.body))
    end

    def payload_for(document)
      {
        account: {
          name: @account.name,
          owner_language: @account.ai_preferred_language.presence || "es"
        },
        property: PROPERTY_ATTRIBUTES.index_with { |attribute| @property.public_send(attribute) if @property.respond_to?(attribute) },
        document: document.slice(:filename, :content_type, :text, :base64, :kind)
      }
    end

    def normalize_response(body)
      property_attributes = body.fetch("property", {}).to_h
        .slice(*PROPERTY_ATTRIBUTES)
        .compact_blank

      faqs = Array(body["faqs"]).map do |row|
        row.to_h
          .slice("question", "answer", "category")
          .compact_blank
      end.select { |row| row["question"].present? && row["answer"].present? }

      Result.new(
        property_attributes: property_attributes,
        faqs: faqs,
        source_summary: body["source_summary"].to_s
      )
    end

    def report_error(error)
      ErrorReporter.report(
        error,
        source: "property_import",
        severity: "warning",
        account: @account,
        property: @property&.persisted? ? @property : nil,
        context: {
          ai_service_url: ENV["AI_SERVICE_URL"],
          filename: @upload&.original_filename,
          content_type: @upload&.content_type,
          size: @upload&.size
        }
      )
    end
  end
end
