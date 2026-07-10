require "set"

module Conversations
  class Deduplicator
    LEGACY_INDEX_NAME = "index_conversations_on_guest_id_and_channel_unique".freeze
    INDEX_NAME = "index_conversations_on_channel_and_channel_participant".freeze
    DEFAULT_CHANNEL = "whatsapp".freeze

    Result = Struct.new(:dry_run, :groups, :merged_groups, :moved_counts, :possible_duplicate_messages, :deleted_conversation_ids, keyword_init: true) do
      def duplicate_group_count
        groups.size
      end

      def changed?
        moved_counts.values.sum.positive? || deleted_conversation_ids.any?
      end
    end

    def initialize(dry_run: true, logger: Rails.logger)
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
      @logger = logger
      @moved_counts = Hash.new(0)
      @possible_duplicate_messages = []
      @deleted_conversation_ids = []
    end

    def call
      groups = duplicate_groups
      merged_groups = []

      groups.each do |group|
        merged_groups << merge_group(group)
      end

      Result.new(
        dry_run: @dry_run,
        groups: groups,
        merged_groups: merged_groups,
        moved_counts: @moved_counts,
        possible_duplicate_messages: @possible_duplicate_messages,
        deleted_conversation_ids: @deleted_conversation_ids
      )
    end

    def duplicate_groups
      rows = Conversation
        .joins(:guest)
        .select(
          "COALESCE(NULLIF(conversations.channel_participant, ''), NULLIF(guests.phone_number, ''), 'guest:' || conversations.guest_id::text) AS normalized_participant",
          "COALESCE(NULLIF(conversations.channel, ''), '#{DEFAULT_CHANNEL}') AS normalized_channel",
          "COUNT(*) AS conversations_count"
        )
        .group(
          "COALESCE(NULLIF(conversations.channel_participant, ''), NULLIF(guests.phone_number, ''), 'guest:' || conversations.guest_id::text)",
          "COALESCE(NULLIF(conversations.channel, ''), '#{DEFAULT_CHANNEL}')"
        )
        .having("COUNT(*) > 1")

      rows.map do |row|
        conversations = Conversation
          .joins(:guest)
          .where(
            "COALESCE(NULLIF(conversations.channel_participant, ''), NULLIF(guests.phone_number, ''), 'guest:' || conversations.guest_id::text) = ?",
            row.normalized_participant
          )
          .where("COALESCE(NULLIF(conversations.channel, ''), ?) = ?", DEFAULT_CHANNEL, row.normalized_channel)
          .includes(:messages, :property, :guest)
          .to_a

        {
          channel_participant: row.normalized_participant,
          channel: row.normalized_channel,
          conversation_ids: conversations.map(&:id),
          conversations: conversations
        }
      end
    end

    private

    def merge_group(group)
      conversations = group.fetch(:conversations)
      canonical = canonical_conversation(conversations)
      duplicates = conversations.reject { |conversation| conversation.id == canonical.id }
      latest = conversations.max_by { |conversation| [conversation.updated_at || Time.at(0), conversation.id] }

      summary = {
        channel_participant: group.fetch(:channel_participant),
        channel: group.fetch(:channel),
        canonical_id: canonical.id,
        duplicate_ids: duplicates.map(&:id),
        current_guest_id: latest.guest_id,
        current_property_id: latest.property_id
      }

      log("duplicate_group #{summary.to_json}")
      return summary.merge(dry_run: true) if @dry_run

      Conversation.transaction do
        canonical.update_columns(
          guest_id: latest.guest_id,
          property_id: latest.property_id,
          channel: group.fetch(:channel),
          channel_participant: group.fetch(:channel_participant),
          updated_at: Time.current
        )
        duplicates.each { |duplicate| merge_duplicate!(canonical, duplicate) }
        canonical.update_columns(last_message_at: canonical.messages.maximum(:created_at), updated_at: Time.current)
      end

      summary.merge(dry_run: false)
    end

    def canonical_conversation(conversations)
      counts = Message.where(conversation_id: conversations.map(&:id)).group(:conversation_id).count
      conversations.max_by do |conversation|
        [
          counts.fetch(conversation.id, 0),
          -conversation.created_at.to_i,
          -conversation.id
        ]
      end
    end

    def merge_duplicate!(canonical, duplicate)
      move_messages!(canonical, duplicate)
      move_alerts!(canonical, duplicate)
      move_guest_requests!(canonical, duplicate)
      move_ai_decision_logs!(canonical, duplicate)

      duplicate.association(:messages).reset
      duplicate.association(:alerts).reset
      duplicate.association(:guest_requests).reset
      duplicate.destroy!
      @deleted_conversation_ids << duplicate.id
    end

    def move_messages!(canonical, duplicate)
      canonical_keys = Message.where(conversation_id: canonical.id).filter_map { |message| stable_message_key(message) }.to_set

      duplicate.messages.order(:created_at, :id).find_each do |message|
        stable_key = stable_message_key(message)

        if stable_key.present? && canonical_keys.include?(stable_key)
          canonical_message = Message.where(conversation_id: canonical.id).detect { |candidate| stable_message_key(candidate) == stable_key }
          reassign_message_references!(from: message, to: canonical_message)
          message.destroy!
          @moved_counts[:duplicate_messages_removed] += 1
          next
        end

        if stable_key.blank?
          @possible_duplicate_messages << {
            duplicate_conversation_id: duplicate.id,
            message_id: message.id,
            reason: "missing_stable_provider_message_id"
          }
        else
          canonical_keys << stable_key
        end

        message.update_columns(conversation_id: canonical.id)
        @moved_counts[:messages] += 1
      end
    end

    def move_alerts!(canonical, duplicate)
      count = Alert.where(conversation_id: duplicate.id).update_all(conversation_id: canonical.id)
      @moved_counts[:alerts] += count
    end

    def move_guest_requests!(canonical, duplicate)
      count = GuestRequest.where(conversation_id: duplicate.id).update_all(conversation_id: canonical.id)
      @moved_counts[:guest_requests] += count
    end

    def move_ai_decision_logs!(canonical, duplicate)
      count = AIDecisionLog.where(conversation_id: duplicate.id).update_all(conversation_id: canonical.id)
      @moved_counts[:ai_decision_logs] += count
    end

    def reassign_message_references!(from:, to:)
      Alert.where(original_message_id: from.id).update_all(original_message_id: to.id)
      GuestRequest.where(message_id: from.id).update_all(message_id: to.id)
      AIDecisionLog.where(message_id: from.id).update_all(message_id: to.id)
      AIDecisionLog.where(original_message_id: from.id).update_all(original_message_id: to.id)
      Faq.where(source_message_id: from.id).update_all(source_message_id: to.id)
    end

    def stable_message_key(message)
      metadata = message.metadata.to_h
      metadata["provider_message_id"].presence ||
        metadata["MessageSid"].presence ||
        metadata["message_sid"].presence ||
        metadata["SmsMessageSid"].presence ||
        metadata["WaId"].presence ||
        metadata["wamid"].presence
    end

    def log(message)
      @logger&.info("[conversations:deduplicate] #{message}")
    end
  end
end
