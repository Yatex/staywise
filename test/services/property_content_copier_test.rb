require "test_helper"

class PropertyContentCopierTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Copy Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @source = @account.properties.create!(
      name: "Source Apartment",
      tags: %w[beach premium],
      check_in_time: "2:00 PM",
      ai_general_notes: "Use source notes."
    )
    @target = @account.properties.create!(name: "Target Apartment")

    @source.knowledge_blocks.create!(
      title: "WiFi",
      category: "wifi",
      content: "Network is Source WiFi.",
      status: "active"
    )
    @source.recommendations.create!(
      name: "Source Cafe",
      category: "cafe",
      description: "Good breakfast nearby."
    )
    @source.faqs.create!(
      question: "Where is parking?",
      answer: "Street parking is available.",
      category: "parking"
    )
  end

  test "copies selected property content into another property" do
    copied = Properties::ContentCopier.new(
      source: @source,
      target: @target,
      content_types: %w[settings tags guides recommendations faqs]
    ).call

    assert_equal %w[settings tags guides recommendations faqs], copied
    assert_equal "2:00 PM", @target.reload.check_in_time
    assert_equal %w[beach premium], @target.tags
    assert_equal "WiFi", @target.knowledge_blocks.first.title
    assert_equal "Source Cafe", @target.recommendations.first.name
    assert_equal "Where is parking?", @target.faqs.first.question
  end
end
