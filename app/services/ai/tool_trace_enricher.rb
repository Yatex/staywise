require "digest"
require "set"

module AI
  class ToolTraceEnricher
    def initialize(conversation:, guest_message:, tool_calls:, evidence_catalog:, referenced_evidence_ids:, validation_results:, decision_context_id:)
      @conversation = conversation
      @guest_message = guest_message
      @tool_calls = Array(tool_calls)
      @evidence_catalog = Array(evidence_catalog).map { |item| item.to_h.deep_stringify_keys }
      @referenced_evidence_ids = Array(referenced_evidence_ids).compact_blank.map(&:to_s).to_set
      @validation_results = validation_results.to_h.deep_stringify_keys
      @decision_context_id = decision_context_id.to_s
      @property = conversation.property
      @account = @property.account
      @guest = conversation.guest
      @properties_by_id = properties_by_id
      @accounts_by_id = accounts_by_id
      @validation_by_evidence_id = Array(@validation_results["evidence"])
        .map { |item| item.to_h.deep_stringify_keys }
        .index_by { |item| item["evidence_id"].to_s }
    end

    def call
      @tool_calls.map do |raw_tool|
        tool = raw_tool.to_h.deep_stringify_keys
        tool_name = tool["tool_name"].presence || tool["toolName"].presence || "tool"
        returned_evidence = evidence_for_tool(tool_name, tool).map { |item| enriched_evidence(item) }

        tool.merge(
          "context" => resolved_context,
          "request" => tool["input"].presence || {},
          "response" => tool.key?("output") ? tool["output"] : tool["output_summary"],
          "evidence_returned" => returned_evidence,
          "evidence_referenced" => returned_evidence.select { |item| item["referenced"] }
        )
      end
    end

    private

    def resolved_context
      {
        "conversation_id" => @conversation.id,
        "reservation_id" => @guest.reservation_reference.presence,
        "property_id" => @property.id,
        "property_name" => @property.display_name,
        "account_id" => @account.id,
        "account_name" => @account.name,
        "decision_context_fingerprint" => decision_context_fingerprint
      }
    end

    def decision_context_fingerprint
      return if @decision_context_id.blank?

      "sha256:#{Digest::SHA256.hexdigest(@decision_context_id).first(16)}"
    end

    def evidence_for_tool(tool_name, tool)
      extracted = extract_evidence(tool["output"], tool_name)
      return extracted if extracted.present?

      @evidence_catalog.select { |item| item["tool_name"].to_s == tool_name.to_s }
    end

    def extract_evidence(value, tool_name)
      items = case value
      when Array
        value.flat_map { |item| extract_evidence(item, tool_name) }
      when Hash
        hash = value.to_h.deep_stringify_keys
        direct = direct_evidence(hash, tool_name)
        nested = hash.values.flat_map { |item| extract_evidence(item, tool_name) }
        (direct.present? ? [direct] : []) + nested
      else
        []
      end

      items.uniq { |item| [item["evidence_id"], item["value"].to_s] }
    end

    def direct_evidence(hash, tool_name)
      raw_id = hash["evidence_id"].presence || hash["source_id"].presence || hash["id"].presence
      value = hash.key?("value") ? hash["value"] : (hash.key?("content") ? hash["content"] : hash["excerpt"])
      return if raw_id.blank? || value.nil?

      catalog_item = @evidence_catalog.find do |item|
        item["tool_name"].to_s == tool_name.to_s &&
          [item["evidence_id"], item["raw_id"]].compact.map(&:to_s).include?(raw_id.to_s)
      end
      catalog_item ||= @evidence_catalog.find do |item|
        [item["evidence_id"], item["raw_id"]].compact.map(&:to_s).include?(raw_id.to_s)
      end
      return catalog_item if catalog_item.present?

      {
        "evidence_id" => hash["evidence_id"].presence || raw_id,
        "raw_id" => raw_id,
        "field" => hash["field"],
        "label" => hash["label"].presence || hash["title"],
        "source_type" => hash["source_type"].presence || hash["type"],
        "value" => value,
        "tool_name" => tool_name,
        "metadata" => hash.except("value", "content", "excerpt")
      }
    end

    def enriched_evidence(item)
      metadata = item["metadata"].to_h.deep_stringify_keys
      evidence_id = item["evidence_id"].presence || item["raw_id"].presence
      scope = metadata["scope"].presence || item["scope"].presence || inferred_scope(metadata)
      property_id = metadata["property_id"].presence || item["property_id"].presence
      property_id ||= @property.id if scope == "property"
      account_id = metadata["account_id"].presence || item["account_id"].presence
      account_id ||= property_for(property_id)&.account_id
      account_id ||= @account.id if scope.in?(%w[property account])
      validation = @validation_by_evidence_id[evidence_id.to_s].to_h.deep_stringify_keys
      referenced = evidence_referenced?(item)

      {
        "evidence_id" => evidence_id,
        "type" => item["source_type"].presence || metadata["source_type"].presence || metadata["type"].presence,
        "title" => item["label"].presence || item["field"].presence || metadata["title"].presence || metadata["label"].presence,
        "content" => item.key?("value") ? item["value"] : metadata["content"],
        "property_id" => property_id,
        "property_name" => property_for(property_id)&.display_name,
        "account_id" => account_id,
        "account_name" => account_for(account_id)&.name,
        "scope" => scope,
        "tool_name" => item["tool_name"],
        "referenced" => referenced,
        "validation" => validation,
        "validation_passed" => validation_passed?(validation),
        "validation_label" => validation_label(validation, referenced)
      }
    end

    def evidence_referenced?(item)
      candidates = [
        item["evidence_id"],
        item["raw_id"],
        item.dig("metadata", "id"),
        item.dig("metadata", "source_id"),
        item.dig("metadata", "evidence_id")
      ].compact.map(&:to_s)

      candidates.any? { |candidate| @referenced_evidence_ids.include?(candidate) }
    end

    def validation_passed?(validation)
      return nil if validation.blank?

      validation["authorized"] != false && validation["valid"] != false
    end

    def validation_label(validation, referenced)
      return "No referenciada; Rails no necesitó validarla" if validation.blank? && !referenced
      return "Sin resultado de validación" if validation.blank?

      reason = validation["provenance_reason"].presence
      return "Cross-property evidence" if reason == "cross_property"
      return reason.humanize if reason.present? && reason != "property_match"
      return "Property matches conversation" if validation_passed?(validation) && validation["scope"] == "property"
      return "Account scope validated" if validation_passed?(validation) && validation["scope"] == "account"

      validation_passed?(validation) ? "Evidencia validada" : "Evidencia rechazada"
    end

    def inferred_scope(metadata)
      metadata["property_id"].present? ? "property" : (metadata["account_id"].present? ? "account" : nil)
    end

    def properties_by_id
      ids = @evidence_catalog.filter_map do |item|
        metadata = item["metadata"].to_h
        metadata["property_id"].presence || item["property_id"].presence
      end
      ids << @property.id
      Property.includes(:account).where(id: ids.compact.uniq).index_by { |property| property.id.to_s }
    end

    def accounts_by_id
      ids = @evidence_catalog.filter_map do |item|
        metadata = item["metadata"].to_h
        metadata["account_id"].presence || item["account_id"].presence
      end
      ids.concat(@properties_by_id.values.map(&:account_id))
      ids << @account.id
      Account.where(id: ids.compact.uniq).index_by { |account| account.id.to_s }
    end

    def property_for(property_id)
      @properties_by_id[property_id.to_s]
    end

    def account_for(account_id)
      @accounts_by_id[account_id.to_s]
    end
  end
end
