module Properties
  class ContentCopier
    CONTENT_TYPES = %w[settings tags guides recommendations faqs].freeze

    def initialize(source:, target:, content_types:)
      @source = source
      @target = target
      @content_types = Array(content_types).select { |type| CONTENT_TYPES.include?(type.to_s) }.map(&:to_s)
    end

    def call
      ActiveRecord::Base.transaction do
        copy_settings if selected?("settings")
        copy_tags if selected?("tags")
        copy_guides if selected?("guides")
        copy_recommendations if selected?("recommendations")
        copy_faqs if selected?("faqs")
      end

      @content_types
    end

    private

    def selected?(type)
      @content_types.include?(type)
    end

    def copy_settings
      attrs = @source.copyable_settings.except("tags")
      @target.update!(attrs)
    end

    def copy_tags
      @target.update!(tags: (@target.tags + @source.tags).uniq)
    end

    def copy_guides
      @source.knowledge_blocks.find_each do |block|
        @target.knowledge_blocks.create!(block.attributes.slice("title", "category", "content", "status"))
      end
    end

    def copy_recommendations
      @source.recommendations.find_each do |recommendation|
        @target.recommendations.create!(
          recommendation.attributes.slice(
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
        )
      end
    end

    def copy_faqs
      @source.faqs.find_each do |faq|
        @target.faqs.create!(faq.attributes.slice("question", "answer", "category", "active"))
      end
    end
  end
end
