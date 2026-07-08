require "json"
require "net/http"
require "set"

module AI
  class PropertyImportService
    PROPERTY_ATTRIBUTES = %w[
      name
      address
      internal_nickname
      check_in_time
      checkout_time
      checkout_instructions
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

    Result = Struct.new(
      :property_attributes,
      :appliance_guides,
      :faqs,
      :recommendations,
      :source_summary,
      keyword_init: true
    ) do
      def useful?
        property_attributes.to_h.values.any?(&:present?) ||
          Array(appliance_guides).any? ||
          Array(faqs).any? ||
          Array(recommendations).any?
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
      document = Properties::UploadTextExtractor.new(@upload).call
      result = import_document(document)
      unless result.useful?
        if document[:text].to_s.strip.present?
          raise ImportError, "Ayla pudo leer el archivo, pero no encontró datos claros para completar la propiedad. Revisá que el archivo tenga nombre, dirección, horarios, WiFi, reglas o FAQs."
        end

        raise ImportError, "No pude extraer campos útiles del archivo. Probá con una imagen más clara o un documento con más texto."
      end

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

    def import_document(document)
      return local_import(document) if ENV["AI_SERVICE_URL"].blank?

      merge_results(remote_import(document), local_import(document))
    rescue StandardError => error
      fallback = local_import(document)
      return fallback if fallback.useful?

      raise error
    end

    def merge_results(primary, fallback)
      return primary unless fallback.useful?

      Result.new(
        property_attributes: fallback.property_attributes.merge(primary.property_attributes),
        appliance_guides: merge_appliance_guides(primary.appliance_guides, fallback.appliance_guides),
        faqs: merge_faqs(primary.faqs, fallback.faqs),
        recommendations: merge_recommendations(primary.recommendations, fallback.recommendations),
        source_summary: [primary.source_summary, fallback.source_summary].compact_blank.join(" ")
      )
    end

    def merge_appliance_guides(primary_guides, fallback_guides)
      merge_rows(primary_guides, fallback_guides, key: "title")
    end

    def merge_recommendations(primary_recommendations, fallback_recommendations)
      merge_rows(primary_recommendations, fallback_recommendations, key: "name")
    end

    def merge_faqs(primary_faqs, fallback_faqs)
      merge_rows(primary_faqs, fallback_faqs, key: "question")
    end

    def merge_rows(primary_rows, fallback_rows, key:)
      seen = Set.new
      (Array(primary_rows) + Array(fallback_rows)).filter_map do |row|
        identity = row[key].to_s.downcase.strip
        next if identity.blank? || seen.include?(identity)

        seen << identity
        row
      end
    end

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

      appliance_guides = Array(body["appliance_guides"]).map do |row|
        row.to_h
          .slice("title", "content", "youtube_url")
          .compact_blank
      end.select { |row| row["title"].present? && row["content"].present? }

      recommendations = Array(body["recommendations"]).map do |row|
        row.to_h
          .slice(
            "name",
            "category",
            "description",
            "address",
            "google_maps_url",
            "website_url",
            "phone_number",
            "owner_note",
            "distance_or_walking_time"
          )
          .compact_blank
      end.select { |row| row["name"].present? }

      Result.new(
        property_attributes: property_attributes,
        appliance_guides: appliance_guides,
        faqs: faqs,
        recommendations: recommendations,
        source_summary: body["source_summary"].to_s
      )
    end

    def local_import(document)
      text = document[:text].to_s
      general_notes = section_between(
        text,
        /notas [uú]tiles(?: durante la estad[ií]a)?/i,
        /electrodom[eé]sticos|recomendaciones|faqs|checkout y salida|instrucciones de salida/i
      )
      appliance_guides = local_appliance_guides(text, general_notes: general_notes)
      attributes = {
        "name" => first_label_value(text, /nombre de la propiedad/i),
        "internal_nickname" => first_label_value(text, /nombre interno|alias interno/i),
        "address" => first_label_value(text, /direcci[oó]n|direccion/i),
        "check_in_time" => first_time_after(text, /check-?in|entrada/i),
        "checkout_time" => first_time_after(text, /check-?out|salida/i),
        "checkout_instructions" => section_between(text, /instrucciones de salida|checkout y salida|salida y checkout/i, /electrodom[eé]sticos|recomendaciones|faqs|notas para/i),
        "wifi_name" => first_label_value(text, /nombre de red|red wifi/i),
        "wifi_password" => first_label_value(text, /contrase[nñ]a|clave/i),
        "house_rules" => section_between(text, /reglas de la casa/i, /emergencias|notas [uú]tiles|electrodom[eé]sticos|recomendaciones|faqs/i),
        "access_instructions" => section_between(text, /acceso al edificio|instrucciones de acceso/i, /estacionamiento|reglas de la casa|emergencias/i),
        "parking_instructions" => section_between(text, /estacionamiento/i, /reglas de la casa|emergencias|notas [uú]tiles/i),
        "emergency_information" => section_between(text, /emergencias/i, /notas [uú]tiles|electrodom[eé]sticos|recomendaciones|faqs/i),
        "ai_general_notes" => notes_without_appliance_lines(general_notes)
      }.compact_blank

      Result.new(
        property_attributes: attributes,
        appliance_guides: appliance_guides,
        faqs: local_faqs(text),
        recommendations: local_recommendations(text),
        source_summary: "Datos extraídos localmente del archivo."
      )
    end

    def first_label_value(text, label_pattern)
      match = text.match(/(?:#{label_pattern.source})\s*:?\s*\n?\s*([^\n]+)/i)
      match&.[](1).to_s.strip.presence
    end

    def first_time_after(text, label_pattern)
      line = text.lines.find { |item| item.match?(label_pattern) }
      return unless line

      line[/\b([01]?\d|2[0-3])[:.][0-5]\d\b/].to_s.tr(".", ":").presence
    end

    def section_between(text, start_pattern, end_pattern)
      match = text.match(/(?:#{start_pattern.source})\s*:?\s*(.*?)(?=\n\s*(?:#{end_pattern.source})\s*:|\z)/im)
      clean_section(match&.[](1))
    end

    def clean_section(value)
      value.to_s.lines.map(&:strip).reject(&:blank?).join("\n").presence
    end

    def local_faqs(text)
      text.scan(/Pregunta:\s*(.*?)\s*Respuesta:\s*(.*?)(?=\n\s*Pregunta:|\z)/im).map do |question, answer|
        {
          "question" => question.to_s.strip,
          "answer" => answer.to_s.strip,
          "category" => nil
        }.compact_blank
      end.select { |row| row["question"].present? && row["answer"].present? }
    end

    def local_appliance_guides(text, general_notes: nil)
      section = section_between(
        text,
        /electrodom[eé]sticos(?: y gu[ií]as de uso)?/i,
        /recomendaciones|faqs|notas para/i
      )
      explicit_guides = structured_section_rows(section).map do |title, content|
        {
          "title" => title,
          "content" => content
        }
      end
      inferred_guides = appliance_guides_from_general_notes(general_notes)

      merge_appliance_guides(explicit_guides, inferred_guides)
    end

    def appliance_guides_from_general_notes(notes)
      appliance_patterns.filter_map do |title, pattern|
        lines = notes.to_s.lines.map(&:strip).select { |line| line.match?(pattern) }
        next if lines.empty?

        {
          "title" => title,
          "content" => lines.join("\n")
        }
      end
    end

    def notes_without_appliance_lines(notes)
      patterns = appliance_patterns.map(&:last)
      remaining = notes.to_s.lines.map(&:strip).reject do |line|
        line.blank? || patterns.any? { |pattern| line.match?(pattern) }
      end
      remaining.join("\n").presence
    end

    def appliance_patterns
      [
        ["Lavarropas y lavadero", /lavarropas|lavadero|secadora|fichas?/i],
        ["Aire acondicionado", /aire acondicionado|control remoto.*(?:fr[ií]o|calor)|climatizaci[oó]n/i],
        ["TV", /smart\s*tv|televisi[oó]n|netflix|control samsung/i],
        ["Horno", /horno|perilla.*temperatura/i],
        ["Cafetera", /cafetera|nespresso|c[aá]psulas?/i],
        ["Lavavajillas", /lavavajillas/i]
      ]
    end

    def local_recommendations(text)
      section = section_between(
        text,
        /recomendaciones locales(?: aprobadas por el anfitri[oó]n)?/i,
        /faqs|preguntas frecuentes|notas para/i
      )

      structured_section_rows(section).filter_map do |category_label, content|
        name, description = content.split(/\s+-\s+/, 2)
        next if name.blank?

        {
          "name" => name.strip,
          "category" => recommendation_category(category_label),
          "description" => description.to_s.strip.presence
        }.compact_blank
      end
    end

    def structured_section_rows(section)
      return [] if section.blank?

      section.scan(/^([^:\n]+):\s*\n(.*?)(?=^[^:\n]+:\s*$|\z)/m).filter_map do |title, content|
        cleaned_title = title.to_s.strip
        cleaned_content = clean_section(content)
        [cleaned_title, cleaned_content] if cleaned_title.present? && cleaned_content.present?
      end
    end

    def recommendation_category(label)
      normalized = I18n.transliterate(label.to_s).downcase
      {
        "cafe" => "cafe",
        "supermercado" => "supermarket",
        "farmacia" => "pharmacy",
        "restaurante" => "restaurant",
        "transporte" => "transport",
        "atraccion" => "attraction"
      }.fetch(normalized, "other")
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
