require "test_helper"

class OwnerTasksCreatorTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Owner task lifecycle")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Palermo Soho")
    @guest = @account.guests.create!(phone_number: "+59899001234", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
  end

  test "clarifications update the selected open need without copying messages or notifying again" do
    notifications = []

    Whatsapp::OwnerEscalationNotifier.stub(:call, ->(**args) { notifications << args[:item] }) do
      first = create_task(
        body: "Quiero una cuna",
        title: "Solicitar una cuna",
        action_type: "request_extra_item"
      )
      updated = create_task(
        body: "Para hoy, dejarla en el hall",
        title: "Dejar cuna hoy en hall",
        owner_task_id: first.id,
        action_type: "request_extra_item"
      )

      assert_equal first.id, updated.id
      assert_equal 1, @conversation.owner_tasks.count
      assert_equal "Dejar cuna hoy en hall", updated.reload.title
      assert_nil updated.message_id
      assert_nil updated.description
      assert_empty updated.metadata.slice("updates", "last_update_message_id")
      assert_equal 1, notifications.size
    end
  end

  test "a distinct intention creates a second owner task" do
    cot = create_task(body: "Quiero una cuna", title: "Solicitar una cuna", action_type: "request_extra_item")
    checkin = create_task(body: "También quisiera early check-in", title: "Aprobar early check-in", action_type: "request_early_checkin")

    assert_not_equal cot.id, checkin.id
    assert_equal 2, @conversation.owner_tasks.open.count
    assert_equal ["Aprobar early check-in", "Solicitar una cuna"], @conversation.owner_tasks.pluck(:title).sort
  end

  test "a resolved task cannot be selected for an update" do
    task = create_task(body: "Quiero una cuna", title: "Solicitar una cuna", action_type: "request_extra_item")
    task.update!(status: "resolved")
    decision = decision(title: "Agregar detalle de cuna", owner_task_id: task.id, action_type: "request_extra_item")

    validation = AI::DecisionValidator.new(conversation: @conversation, decision: decision).call

    assert_not validation.valid?
    assert_includes validation.reasons, "owner_task_reference_invalid"
  end

  test "AI context exposes only open tasks from the current conversation" do
    open_task = create_task(body: "Quiero una cuna", title: "Solicitar una cuna", action_type: "request_extra_item")
    resolved_task = create_task(body: "Quiero toallas", title: "Enviar toallas", action_type: "request_extra_item")
    resolved_task.update!(status: "resolved")
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Para hoy")

    context = AI::ContextBuilder.new(conversation: @conversation, guest_message: message).call

    assert_equal [open_task.id], context.fetch(:open_owner_tasks).pluck("id")
    assert_equal "Solicitar una cuna", context.fetch(:open_owner_tasks).first.fetch("title")
  end

  private

  def create_task(body:, title:, action_type:, owner_task_id: nil)
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
    OwnerTasks::Creator.call(
      conversation: @conversation,
      decision: decision(title: title, owner_task_id: owner_task_id, action_type: action_type),
      guest_message: message
    )
  end

  def decision(title:, action_type:, owner_task_id: nil)
    AI::DecisionResult.from_hash(
      action: "create_owner_task",
      owner_task_kind: "request",
      owner_task_id: owner_task_id,
      title: title,
      language: "es",
      message: "Recibí tu pedido.",
      task_summary: title,
      answer_confidence: 98,
      evidence_ids: [],
      proposed_action: { type: action_type, payload: {} }
    )
  end
end
