module AI
  class ContextBuilder
    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @guest = conversation.guest
    end

    def call
      {
        guest_message: @guest_message.body,
        guest: guest_payload,
        property: property_payload,
        owner_instructions: owner_instructions_payload,
        knowledge_blocks: knowledge_blocks_payload,
        faqs: faqs_payload,
        recommendations: recommendations_payload,
        conversation_history: conversation_history_payload
      }
    end

    private

    def guest_payload
      {
        name: @guest.name,
        phone_number: @guest.phone_number,
        language: @guest.language,
        reservation_reference: @guest.reservation_reference,
        check_in_date: @guest.check_in_date,
        checkout_date: @guest.checkout_date
      }
    end

    def property_payload
      @property.slice(
        :name,
        :address,
        :internal_nickname,
        :check_in_time,
        :checkout_time,
        :wifi_name,
        :wifi_password,
        :house_rules,
        :access_instructions,
        :parking_instructions,
        :emergency_information,
        :owner_contact_instructions,
        :ai_general_notes,
        :ai_enabled
      )
    end

    def owner_instructions_payload
      account = @property.account
      account.slice(
        :default_ai_instructions,
        :ai_tone,
        :ai_goal,
        :ai_response_style,
        :ai_preferred_language,
        :ai_default_channel,
        :languages_supported,
        :unsure_behavior,
        :late_checkout_policy,
        :emergency_contact_behavior,
        :ai_escalation_rules,
        :ai_automation_settings
      ).merge(ai_active: account.ai_active?)
    end

    def knowledge_blocks_payload
      @property.knowledge_blocks.active.order(:category, :title).map do |block|
        block.slice(:title, :category, :content, :status)
      end
    end

    def faqs_payload
      @property.faqs.active.order(:category, :question).map do |faq|
        faq.slice(:question, :answer, :category)
      end
    end

    def recommendations_payload
      @property.recommendations.order(:category, :name).map do |recommendation|
        recommendation.slice(
          :name,
          :category,
          :description,
          :address,
          :google_maps_url,
          :website_url,
          :phone_number,
          :owner_note,
          :distance_or_walking_time
        )
      end
    end

    def conversation_history_payload
      @conversation.messages.order(created_at: :desc).limit(12).reverse.map do |message|
        message.slice(:sender, :body, :channel, :created_at)
      end
    end
  end
end
