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

ActiveRecord::Schema[7.1].define(version: 2026_06_30_225438) do
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
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
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
    t.index ["alert_type", "priority"], name: "index_alerts_on_alert_type_and_priority"
    t.index ["conversation_id"], name: "index_alerts_on_conversation_id"
    t.index ["guest_id"], name: "index_alerts_on_guest_id"
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
    t.index ["property_id", "active"], name: "index_faqs_on_property_id_and_active"
    t.index ["property_id"], name: "index_faqs_on_property_id"
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
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
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
    t.index ["account_id", "name"], name: "index_properties_on_account_id_and_name"
    t.index ["account_id"], name: "index_properties_on_account_id"
    t.index ["tags"], name: "index_properties_on_tags", using: :gin
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
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "alerts", "conversations"
  add_foreign_key "alerts", "guests"
  add_foreign_key "alerts", "properties"
  add_foreign_key "billing_events", "accounts"
  add_foreign_key "conversations", "guests"
  add_foreign_key "conversations", "properties"
  add_foreign_key "faqs", "properties"
  add_foreign_key "guests", "accounts"
  add_foreign_key "guests", "properties"
  add_foreign_key "knowledge_blocks", "properties"
  add_foreign_key "messages", "conversations"
  add_foreign_key "operational_errors", "accounts"
  add_foreign_key "operational_errors", "properties"
  add_foreign_key "properties", "accounts"
  add_foreign_key "recommendations", "properties"
  add_foreign_key "subscriptions", "accounts"
  add_foreign_key "users", "accounts"
end
