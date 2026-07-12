# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_07_11_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug"
    t.text "default_ai_instructions"
    t.string "ai_tone", default: "friendly", null: false
    t.string "languages_supported"
    t.text "unsure_behavior"
    t.string "late_checkout_policy", default: "always_escalate", null: false
    t.text "emergency_contact_behavior"
    t.boolean "whatsapp_enabled", default: false, null: false
    t.boolean "email_alerts_enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "ai_active", default: true, null: false
    t.text "ai_goal"
    t.string "ai_response_style", default: "concise", null: false
    t.string "ai_preferred_language", default: "auto", null: false
    t.string "ai_default_channel", default: "whatsapp", null: false
    t.jsonb "ai_escalation_rules", default: {}, null: false
    t.jsonb "ai_automation_settings", default: {}, null: false
    t.string "owner_whatsapp_number"
    t.boolean "owner_whatsapp_escalations_enabled", default: false, null: false
    t.integer "ai_high_score_threshold", default: 75, null: false
    t.integer "ai_medium_score_threshold", default: 40, null: false
    t.integer "ai_safety_score_threshold", default: 75, null: false
    t.integer "ai_max_clarification_attempts", default: 2, null: false
    t.integer "ai_answer_confidence_threshold", default: 90, null: false
    t.index ["owner_whatsapp_number"], name: "index_accounts_on_owner_whatsapp_number"
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
  end

  create_table "ai_decision_logs", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "property_id"
    t.bigint "guest_id"
    t.bigint "conversation_id"
    t.bigint "message_id"
    t.string "route", null: false
    t.string "decision"
    t.string "language"
    t.string "validator_result"
    t.text "rejection_reason"
    t.boolean "escalation_required", default: false, null: false
    t.boolean "replied_candidate", default: false, null: false
    t.integer "latency_ms"
    t.string "model"
    t.jsonb "detected_intents", default: [], null: false
    t.jsonb "evidence_ids", default: [], null: false
    t.jsonb "missing_information", default: [], null: false
    t.jsonb "safety_flags", default: [], null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "original_message_id"
    t.jsonb "ai_request_payload", default: {}, null: false
    t.jsonb "ai_response_payload", default: {}, null: false
    t.jsonb "tool_calls", default: [], null: false
    t.jsonb "validation_results", default: {}, null: false
    t.string "fallback_reason"
    t.string "final_outcome"
    t.string "provider_delivery_status"
    t.index ["account_id"], name: "index_ai_decision_logs_on_account_id"
    t.index ["conversation_id"], name: "index_ai_decision_logs_on_conversation_id"
    t.index ["fallback_reason", "created_at"], name: "index_ai_decision_logs_on_fallback_reason_and_created_at"
    t.index ["final_outcome", "created_at"], name: "index_ai_decision_logs_on_final_outcome_and_created_at"
    t.index ["guest_id"], name: "index_ai_decision_logs_on_guest_id"
    t.index ["message_id"], name: "index_ai_decision_logs_on_message_id"
    t.index ["original_message_id"], name: "index_ai_decision_logs_on_original_message_id"
    t.index ["property_id", "created_at"], name: "index_ai_decision_logs_on_property_id_and_created_at"
    t.index ["property_id"], name: "index_ai_decision_logs_on_property_id"
    t.index ["provider_delivery_status", "created_at"], name: "idx_on_provider_delivery_status_created_at_294904be25"
    t.index ["route", "created_at"], name: "index_ai_decision_logs_on_route_and_created_at"
    t.index ["validator_result", "created_at"], name: "index_ai_decision_logs_on_validator_result_and_created_at"
  end

  create_table "alerts", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.bigint "guest_id"
    t.bigint "conversation_id"
    t.string "alert_type", null: false
    t.string "title", null: false
    t.text "description"
    t.string "status", default: "open", null: false
    t.string "priority", default: "medium", null: false
    t.text "ai_suggested_action"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "original_message_id"
    t.bigint "ai_decision_log_id"
    t.jsonb "metadata", default: {}, null: false
    t.index ["ai_decision_log_id"], name: "index_alerts_on_ai_decision_log_id"
    t.index ["alert_type", "priority"], name: "index_alerts_on_alert_type_and_priority"
    t.index ["conversation_id"], name: "index_alerts_on_conversation_id"
    t.index ["guest_id"], name: "index_alerts_on_guest_id"
    t.index ["original_message_id"], name: "index_alerts_on_original_message_id"
    t.index ["property_id", "status"], name: "index_alerts_on_property_id_and_status"
    t.index ["property_id"], name: "index_alerts_on_property_id"
  end

  create_table "billing_events", force: :cascade do |t|
    t.bigint "account_id"
    t.string "stripe_event_id", null: false
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_billing_events_on_account_id"
    t.index ["event_type"], name: "index_billing_events_on_event_type"
    t.index ["stripe_event_id"], name: "index_billing_events_on_stripe_event_id", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.bigint "guest_id", null: false
    t.bigint "property_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "last_message_at"
    t.boolean "ai_enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "whatsapp", null: false
    t.string "channel_participant", null: false
    t.index ["channel", "channel_participant"], name: "index_conversations_on_channel_and_channel_participant", unique: true
    t.index ["guest_id", "channel"], name: "index_conversations_on_guest_id_and_channel_unique", unique: true
    t.index ["guest_id"], name: "index_conversations_on_guest_id"
    t.index ["last_message_at"], name: "index_conversations_on_last_message_at"
    t.index ["property_id", "status"], name: "index_conversations_on_property_id_and_status"
    t.index ["property_id"], name: "index_conversations_on_property_id"
  end

  create_table "faqs", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "question", null: false
    t.text "answer", null: false
    t.string "category"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "approved", null: false
    t.string "source_type", default: "manual", null: false
    t.bigint "source_alert_id"
    t.bigint "source_message_id"
    t.jsonb "metadata", default: {}, null: false
    t.index ["property_id", "active"], name: "index_faqs_on_property_id_and_active"
    t.index ["property_id", "source_type"], name: "index_faqs_on_property_id_and_source_type"
    t.index ["property_id", "status"], name: "index_faqs_on_property_id_and_status"
    t.index ["property_id"], name: "index_faqs_on_property_id"
    t.index ["source_alert_id"], name: "index_faqs_on_source_alert_id"
    t.index ["source_message_id"], name: "index_faqs_on_source_message_id"
  end

  create_table "guest_requests", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "property_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "guest_id", null: false
    t.bigint "message_id", null: false
    t.bigint "ai_decision_log_id"
    t.string "guest_phone", null: false
    t.string "property_name", null: false
    t.string "property_address"
    t.string "category", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.text "ai_summary"
    t.string "status", default: "open", null: false
    t.string "priority", default: "normal", null: false
    t.string "source_channel", default: "whatsapp", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "requires_owner_approval", default: false, null: false
    t.jsonb "structured_details", default: {}, null: false
    t.string "kind", default: "request", null: false
    t.index ["account_id", "kind", "status"], name: "index_owner_tasks_on_account_kind_status"
    t.index ["account_id", "status"], name: "index_guest_requests_on_account_id_and_status"
    t.index ["account_id"], name: "index_guest_requests_on_account_id"
    t.index ["ai_decision_log_id"], name: "index_guest_requests_on_ai_decision_log_id"
    t.index ["category", "created_at"], name: "index_guest_requests_on_category_and_created_at"
    t.index ["conversation_id", "created_at"], name: "index_guest_requests_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_guest_requests_on_conversation_id"
    t.index ["guest_id"], name: "index_guest_requests_on_guest_id"
    t.index ["message_id"], name: "index_guest_requests_on_message_id"
    t.index ["message_id"], name: "index_guest_requests_on_message_id_unique", unique: true
    t.index ["property_id", "status"], name: "index_guest_requests_on_property_id_and_status"
    t.index ["property_id"], name: "index_guest_requests_on_property_id"
    t.check_constraint "kind::text = ANY (ARRAY['request'::character varying, 'inquiry'::character varying]::text[])", name: "guest_requests_kind_check"
  end

  create_table "guests", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "property_id"
    t.string "name"
    t.string "phone_number", null: false
    t.string "language"
    t.string "reservation_reference"
    t.date "check_in_date"
    t.date "checkout_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "phone_number"], name: "index_guests_on_account_id_and_phone_number", unique: true
    t.index ["account_id"], name: "index_guests_on_account_id"
    t.index ["property_id"], name: "index_guests_on_property_id"
  end

  create_table "knowledge_blocks", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "title", null: false
    t.string "category", null: false
    t.text "content", null: false
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "youtube_url"
    t.index ["property_id", "category"], name: "index_knowledge_blocks_on_property_id_and_category"
    t.index ["property_id", "status"], name: "index_knowledge_blocks_on_property_id_and_status"
    t.index ["property_id"], name: "index_knowledge_blocks_on_property_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.string "sender", null: false
    t.text "body", null: false
    t.string "channel", default: "whatsapp", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.bigint "property_id"
    t.index ["account_id", "conversation_id", "created_at"], name: "index_messages_on_account_id_conversation_id_created_at"
    t.index ["account_id"], name: "index_messages_on_account_id"
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["property_id"], name: "index_messages_on_property_id"
    t.index ["sender"], name: "index_messages_on_sender"
  end

  create_table "operational_errors", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "property_id"
    t.string "source", null: false
    t.string "severity", default: "error", null: false
    t.string "error_class"
    t.text "message", null: false
    t.jsonb "context", default: {}, null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_operational_errors_on_account_id"
    t.index ["property_id"], name: "index_operational_errors_on_property_id"
    t.index ["resolved_at"], name: "index_operational_errors_on_resolved_at"
    t.index ["severity", "created_at"], name: "index_operational_errors_on_severity_and_created_at"
    t.index ["source", "created_at"], name: "index_operational_errors_on_source_and_created_at"
  end

  create_table "owner_whatsapp_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "alert_id"
    t.string "state", default: "queued", null: false
    t.datetime "last_prompted_at"
    t.datetime "last_owner_message_at"
    t.datetime "resolved_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "active_category"
    t.string "active_item_type"
    t.bigint "active_item_id"
    t.datetime "started_at"
    t.datetime "expires_at"
    t.jsonb "processed_message_sids", default: [], null: false
    t.index ["account_id", "state"], name: "index_owner_whatsapp_sessions_on_account_id_and_state"
    t.index ["account_id"], name: "index_one_active_owner_whatsapp_session_per_account", unique: true, where: "((state)::text = ANY ((ARRAY['menu'::character varying, 'awaiting_owner_reply'::character varying, 'awaiting_learning_confirmation'::character varying])::text[]))"
    t.index ["account_id"], name: "index_owner_whatsapp_sessions_on_account_id"
    t.index ["active_item_type", "active_item_id"], name: "index_owner_sessions_on_active_item"
    t.index ["alert_id"], name: "index_owner_whatsapp_sessions_on_alert_id", unique: true
  end

  create_table "properties", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "address"
    t.string "internal_nickname"
    t.string "check_in_time"
    t.string "checkout_time"
    t.string "wifi_name"
    t.string "wifi_password"
    t.text "house_rules"
    t.text "access_instructions"
    t.text "parking_instructions"
    t.text "emergency_information"
    t.text "owner_contact_instructions"
    t.text "ai_general_notes"
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tags", default: [], null: false, array: true
    t.boolean "ai_enabled", default: true, null: false
    t.string "public_token", null: false
    t.text "checkout_instructions"
    t.datetime "deleted_at"
    t.string "owner_contact_phone"
    t.index ["account_id", "name"], name: "index_properties_on_account_id_and_name"
    t.index ["account_id"], name: "index_properties_on_account_id"
    t.index ["deleted_at"], name: "index_properties_on_deleted_at"
    t.index ["public_token"], name: "index_properties_on_public_token", unique: true
    t.index ["tags"], name: "index_properties_on_tags", using: :gin
  end

  create_table "property_sensitive_data", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "kind", null: false
    t.text "encrypted_value", null: false
    t.boolean "active", default: true, null: false
    t.bigint "created_by_id"
    t.bigint "source_alert_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_property_sensitive_data_on_created_by_id"
    t.index ["property_id", "kind", "active"], name: "index_property_sensitive_data_on_property_kind_active"
    t.index ["property_id"], name: "index_property_sensitive_data_on_property_id"
    t.index ["source_alert_id"], name: "index_property_sensitive_data_on_source_alert_id"
  end

  create_table "recommendations", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "name", null: false
    t.string "category", null: false
    t.text "description"
    t.string "address"
    t.string "google_maps_url"
    t.string "website_url"
    t.string "phone_number"
    t.text "owner_note"
    t.string "distance_or_walking_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.index ["property_id", "active", "category"], name: "index_recommendations_on_property_id_and_active_and_category"
    t.index ["property_id", "category"], name: "index_recommendations_on_property_id_and_category"
    t.index ["property_id"], name: "index_recommendations_on_property_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "plan", default: "starter", null: false
    t.string "status", default: "incomplete", null: false
    t.string "stripe_customer_id"
    t.string "stripe_subscription_id"
    t.datetime "current_period_end"
    t.datetime "trial_ends_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_subscriptions_on_account_id"
    t.index ["stripe_customer_id"], name: "index_subscriptions_on_stripe_customer_id"
    t.index ["stripe_subscription_id"], name: "index_subscriptions_on_stripe_subscription_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "owner", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "email_verified_at"
    t.string "email_verification_token"
    t.datetime "email_verification_sent_at"
    t.datetime "terms_accepted_at"
    t.datetime "privacy_accepted_at"
    t.string "terms_version"
    t.string "privacy_version"
    t.string "legal_acceptance_ip"
    t.text "legal_acceptance_user_agent"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["email_verification_token"], name: "index_users_on_email_verification_token", unique: true
  end

  add_foreign_key "ai_decision_logs", "accounts"
  add_foreign_key "ai_decision_logs", "conversations"
  add_foreign_key "ai_decision_logs", "guests"
  add_foreign_key "ai_decision_logs", "messages"
  add_foreign_key "ai_decision_logs", "messages", column: "original_message_id"
  add_foreign_key "ai_decision_logs", "properties"
  add_foreign_key "alerts", "ai_decision_logs"
  add_foreign_key "alerts", "conversations"
  add_foreign_key "alerts", "guests"
  add_foreign_key "alerts", "messages", column: "original_message_id"
  add_foreign_key "alerts", "properties"
  add_foreign_key "billing_events", "accounts"
  add_foreign_key "conversations", "guests"
  add_foreign_key "conversations", "properties"
  add_foreign_key "faqs", "alerts", column: "source_alert_id"
  add_foreign_key "faqs", "messages", column: "source_message_id"
  add_foreign_key "faqs", "properties"
  add_foreign_key "guest_requests", "accounts"
  add_foreign_key "guest_requests", "ai_decision_logs"
  add_foreign_key "guest_requests", "conversations"
  add_foreign_key "guest_requests", "guests"
  add_foreign_key "guest_requests", "messages"
  add_foreign_key "guest_requests", "properties"
  add_foreign_key "guests", "accounts"
  add_foreign_key "guests", "properties"
  add_foreign_key "knowledge_blocks", "properties"
  add_foreign_key "messages", "accounts"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "properties"
  add_foreign_key "operational_errors", "accounts"
  add_foreign_key "operational_errors", "properties"
  add_foreign_key "owner_whatsapp_sessions", "accounts"
  add_foreign_key "owner_whatsapp_sessions", "alerts"
  add_foreign_key "properties", "accounts"
  add_foreign_key "property_sensitive_data", "alerts", column: "source_alert_id"
  add_foreign_key "property_sensitive_data", "properties"
  add_foreign_key "property_sensitive_data", "users", column: "created_by_id"
  add_foreign_key "recommendations", "properties"
  add_foreign_key "subscriptions", "accounts"
  add_foreign_key "users", "accounts"
end
