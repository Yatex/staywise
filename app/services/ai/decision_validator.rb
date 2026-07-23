module AI
  class DecisionValidator
    Result = Struct.new(:valid?, :reasons, :warnings, :contract_failed?, keyword_init: true)

    ALLOWED_ACTIONS = %w[reply clarify create_owner_task check_out no_action].freeze
    ALLOWED_ATTACHMENT_TYPES = %w[video image document].freeze
    BLOCKING_EVIDENCE_REASONS = %w[cross_property cross_account sensitive_access_unauthorized].freeze
    UNRESOLVED_EVIDENCE_WARNING = "evidence_reference_not_resolved".freeze
    INVALID_OWNER_TASK_REFERENCE_WARNING = "owner_task_reference_invalid".freeze

    def initialize(conversation:, decision:, source: "ai")
      @conversation = conversation
      @decision = decision
      @source = source
      @registry = SourceRegistry.new(conversation: conversation)
    end

    def call
      reasons = []
      reasons.concat(structural_reasons)
      reasons.concat(attachment_reasons)
      evidence_reasons, evidence_warnings = evidence_validation_findings
      owner_task_reasons, owner_task_warnings = owner_task_reference_findings
      reasons.concat(evidence_reasons)
      reasons.concat(owner_task_reasons)
      reasons << "internal_metadata_visible" if internal_metadata_visible?
      reasons << "internal_security_violation" if internal_security_violation?
      reasons << "sensitive_access_without_authorization" if sensitive_access_without_authorization?

      Result.new(
        valid?: reasons.empty?,
        reasons: reasons.uniq,
        warnings: (evidence_warnings + owner_task_warnings).uniq,
        contract_failed?: reasons.any? { |reason| reason.start_with?("contract_") || reason.in?(structural_reason_codes) }
      )
    end

    private

    def structural_reasons
      reasons = []
      reasons << "invalid_action" unless @decision.action.in?(ALLOWED_ACTIONS)
      reasons << "invalid_owner_task_kind" if @decision.owner_task_kind.present? && !@decision.owner_task_kind.in?(OwnerTask::KINDS)
      reasons << "owner_task_kind_required" if @decision.action == "create_owner_task" && @decision.owner_task_kind.blank?
      reasons << "owner_task_kind_not_allowed" if @decision.action != "create_owner_task" && @decision.owner_task_kind.present?
      reasons << "owner_task_title_required" if @decision.action == "create_owner_task" && @decision.title.blank?
      reasons << "owner_task_title_too_long" if @decision.title.present? && @decision.title.split.size > 8
      reasons << "empty_response" if @decision.response_text.blank? && @decision.action != "no_action"
      reasons << "missing_language" if @decision.language.blank?
      reasons << "no_action_must_not_have_response" if @decision.action == "no_action" && @decision.response_text.present?
      reasons << "no_action_must_not_have_effects" if no_action_has_effects?
      reasons << "contract_escalate_requires_escalation_required_true" if escalate_without_required_flag?
      reasons << "contract_no_reply_must_not_send_whatsapp" if no_reply_would_send_whatsapp?
      reasons
    end

    def structural_reason_codes
      %w[
        invalid_action
        invalid_owner_task_kind
        owner_task_kind_required
        owner_task_kind_not_allowed
        owner_task_title_required
        owner_task_title_too_long
        empty_response
        missing_language
        no_action_must_not_have_response
        no_action_must_not_have_effects
        invalid_attachment
      ]
    end

    def owner_task_reference_findings
      return [[], []] if @decision.owner_task_id.blank?
      return [["owner_task_reference_invalid"], []] unless @decision.action == "create_owner_task"

      task = OwnerTask.find_by(id: @decision.owner_task_id)
      return [[], [INVALID_OWNER_TASK_REFERENCE_WARNING]] unless task&.status == "open"

      expected = {
        conversation_id: @conversation.id,
        account_id: @conversation.property.account_id,
        property_id: @conversation.property_id,
        guest_id: @conversation.guest_id,
        kind: @decision.owner_task_kind
      }
      actual = task.attributes.symbolize_keys.slice(*expected.keys)
      return [[], []] if actual == expected

      [[], [INVALID_OWNER_TASK_REFERENCE_WARNING]]
    end

    def no_action_has_effects?
      return false unless @decision.action == "no_action"

      @decision.should_reply ||
        @decision.owner_task_kind.present? ||
        @decision.escalation_required ||
        @decision.proposed_action.present?
    end

    def escalate_without_required_flag?
      return false unless @decision.outcome == "escalate"

      !ActiveModel::Type::Boolean.new.cast(@decision.escalation.to_h["required"])
    end

    def no_reply_would_send_whatsapp?
      return false unless @decision.outcome == "no_reply"

      @decision.should_reply || @decision.response_text.present?
    end

    def evidence_validation_findings
      reasons = []
      warnings = []

      evidence_refs_for_decision.each do |item|
        provenance = @registry.evidence_provenance(item)
        next if provenance[:authorized]

        evidence_id = provenance[:evidence_id].presence || "unknown"
        if provenance[:reason].in?(BLOCKING_EVIDENCE_REASONS)
          reasons << "evidence_provenance_violation:#{evidence_id}:#{provenance[:reason]}"
        else
          warnings << UNRESOLVED_EVIDENCE_WARNING
        end
      end

      [reasons, warnings]
    end

    def attachment_reasons
      @decision.attachments.flat_map do |attachment|
        type = attachment["type"].to_s
        evidence_id = attachment["evidence_id"].to_s
        if !type.in?(ALLOWED_ATTACHMENT_TYPES) || evidence_id.blank?
          ["invalid_attachment"]
        else
          []
        end
      end
    end

    def evidence_refs_for_decision
      refs = Array(@decision.evidence) +
        @decision.evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } } +
        @decision.used_source_ids.map { |source_id| { "id" => source_id } } +
        @decision.attachments.map { |attachment| { "evidence_id" => attachment["evidence_id"] } }

      refs.uniq do |item|
        item.to_h.stringify_keys.values_at("id", "evidence_id", "source_id").compact_blank.first
      end
    end

    def internal_metadata_visible?
      text = @decision.response_text.to_s
      return false if text.blank?

      text.match?(
        /
          \(?\s*(source|source_id|evidence|evidence_id|used_source_ids?|matched_sources?|tool|tools|audit|trace)\s*[:：]|
          \b(property|reservation|guest|account|policy|faq|guide|recommendation|knowledge_block)\.[a-z0-9_.-]+\b|
          \b(property_fact|reservation_fact|knowledge_block|guest_context|property_brain|stay_facts):[a-z0-9_.:-]+\b
        /ix
      )
    end

    def internal_security_violation?
      text = @decision.response_text.to_s
      return false if text.blank?

      text.match?(
        /
          \bauthorization\s*:\s*bearer\b|
          \b(?:api[_-]?key|secret[_-]?key|access[_-]?token)\s*[:=]|
          \b(?:stack\s+trace|traceback|activerecord::|nomethoderror|undefined\s+method)\b
        /ix
      )
    end

    def sensitive_access_without_authorization?
      return false unless @decision.sensitive_info_used || sensitive_evidence?

      !ReservationAuthorization.new(
        guest: @conversation.guest,
        property: @conversation.property
      ).sensitive_access_authorized?
    end

    def sensitive_evidence?
      evidence_refs_for_decision.any? do |item|
        evidence_id = item.to_h.stringify_keys.values_at("id", "evidence_id", "source_id").compact_blank.first.to_s
        evidence_id.in?(%w[
          property_fact:wifi_name
          property_fact:wifi_password
          property_fact:access_instructions
          property.wifi_name
          property.wifi_password
          property.access_instructions
          sensitive_wifi_name
          sensitive_wifi_password
          sensitive_access_instructions
        ])
      end
    end
  end
end
