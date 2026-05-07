require "net/http"
require "json"

module AI
  class DecisionService
    KEYWORD_ALERTS = {
      late_checkout_request: %w[late checkout stay longer leave later],
      missing_item: %w[towel towels linen sheets missing],
      maintenance_issue: %w[broken leak leaking damage not\ working],
      emergency: %w[emergency hospital police fire ambulance urgent],
      complaint: %w[complaint dirty bad unhappy disappointed],
      owner_approval_required: %w[refund discount compensation approve permission]
    }.freeze

    def self.call(conversation:, guest_message:)
      new(conversation: conversation, guest_message: guest_message).call
    end

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
    end

    def call
      payload = ContextBuilder.new(conversation: @conversation, guest_message: @guest_message).call
      remote_decision(payload) || local_decision(payload)
    end

    private

    def remote_decision(payload)
      return if ENV["AI_SERVICE_URL"].blank?

      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/decide")
      response = Net::HTTP.post(
        uri,
        payload.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )

      return unless response.is_a?(Net::HTTPSuccess)

      DecisionResult.from_hash(JSON.parse(response.body))
    rescue StandardError => error
      Rails.logger.warn("[ai-decision] remote fallback: #{error.class}: #{error.message}")
      nil
    end

    def local_decision(payload)
      text = payload[:guest_message].to_s.downcase
      alert_type = detected_alert_type(text)

      return alert_decision(alert_type, payload[:guest_message]) if alert_type

      if recommendation_question?(text)
        recommendation_decision(payload)
      else
        knowledge_decision(payload, text)
      end
    end

    def detected_alert_type(text)
      KEYWORD_ALERTS.find do |_type, keywords|
        keywords.any? { |keyword| text.include?(keyword.tr("\\", "")) }
      end&.first
    end

    def alert_decision(alert_type, body)
      title = alert_type.to_s.humanize
      DecisionResult.from_hash(
        response_text: "I will check this with your host and get back to you shortly.",
        should_reply: true,
        confidence: 0.92,
        escalation_required: true,
        alert_type: alert_type,
        alert_title: title,
        alert_description: body,
        suggested_owner_action: suggested_action_for(alert_type)
      )
    end

    def recommendation_question?(text)
      text.match?(/eat|restaurant|cafe|coffee|supermarket|pharmacy|medicine|visit|attraction|transport|move around/)
    end

    def recommendation_decision(payload)
      recommendations = payload[:recommendations].first(3)

      if recommendations.any?
        lines = recommendations.map do |item|
          note = [item["description"], item["distance_or_walking_time"], item["owner_note"]].compact_blank.join(" ")
          "- #{item["name"]}: #{note.presence || item["category"].to_s.humanize}"
        end

        DecisionResult.from_hash(
          response_text: "Here are a few host-recommended options:\n#{lines.join("\n")}",
          should_reply: true,
          confidence: 0.74,
          escalation_required: false
        )
      else
        unknown_decision("Guest asked for a local recommendation, but none are configured.")
      end
    end

    def knowledge_decision(payload, text)
      faq = payload[:faqs].find { |item| relevant?(text, item["question"]) }
      return answer_decision(faq["answer"], 0.83) if faq

      block = payload[:knowledge_blocks].find { |item| relevant?(text, [item["title"], item["category"], item["content"]].join(" ")) }
      return answer_decision(block["content"], 0.71) if block

      unknown_decision("The AI could not find owner-provided information for: #{payload[:guest_message]}")
    end

    def relevant?(message, source)
      words = message.scan(/[a-z0-9]+/).reject { |word| word.length < 4 }
      return false if words.blank?

      source_text = source.to_s.downcase
      words.any? { |word| source_text.include?(word) }
    end

    def answer_decision(answer, confidence)
      DecisionResult.from_hash(
        response_text: answer,
        should_reply: true,
        confidence: confidence,
        escalation_required: false
      )
    end

    def unknown_decision(description)
      DecisionResult.from_hash(
        response_text: "I do not have that information yet. I will check with your host and get back to you shortly.",
        should_reply: true,
        confidence: 0.28,
        escalation_required: true,
        alert_type: "unknown_question",
        alert_title: "Question needs host input",
        alert_description: description,
        suggested_owner_action: "Add the answer to this property's guest guide or FAQ, then reply to the guest."
      )
    end

    def suggested_action_for(alert_type)
      {
        late_checkout_request: "Confirm availability and whether a fee applies before approving.",
        missing_item: "Coordinate replacement items and let the guest know the timing.",
        maintenance_issue: "Assess urgency, contact maintenance, and update the guest.",
        emergency: "Contact the guest immediately and share emergency instructions.",
        complaint: "Review the issue, acknowledge the complaint, and decide on next steps.",
        owner_approval_required: "Review the request before the AI or owner confirms anything."
      }.fetch(alert_type, "Review and respond from the conversation.")
    end
  end
end
