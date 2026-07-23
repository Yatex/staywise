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

  test "a resolved task reference becomes a warning and creates a new task" do
    task = create_task(body: "Quiero una cuna", title: "Solicitar una cuna", action_type: "request_extra_item")
    task.update!(status: "resolved")
    decision = decision(title: "Agregar detalle de cuna", owner_task_id: task.id, action_type: "request_extra_item")

    validation = AI::DecisionValidator.new(conversation: @conversation, decision: decision).call
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Quiero otra cuna")
    created = OwnerTasks::Creator.call(conversation: @conversation, decision: decision, guest_message: message)

    assert validation.valid?
    assert_includes validation.warnings, "owner_task_reference_invalid"
    assert_not_equal task.id, created.id
    assert_equal "open", created.status
  end

  test "a nonexistent task reference creates a new local task with a warning" do
    decision = decision(title: "Solicitar una cama adicional", owner_task_id: 999_999_999, action_type: "request_extra_bed")
    validation = AI::DecisionValidator.new(conversation: @conversation, decision: decision).call
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Quiero una cama adicional")

    created = OwnerTasks::Creator.call(conversation: @conversation, decision: decision, guest_message: message)

    assert validation.valid?
    assert_includes validation.warnings, "owner_task_reference_invalid"
    assert_equal "Solicitar una cama adicional", created.title
    assert_equal @conversation, created.conversation
  end

  test "a task reference from another conversation or account is never updated" do
    other_account = Account.create!(name: "Other owner")
    other_account.subscriptions.create!(plan: "growth", status: "trialing")
    other_property = other_account.properties.create!(name: "Other property")
    other_guest = other_account.guests.create!(phone_number: "+59899009999", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    external_message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito una cama")
    external_task = OwnerTasks::Creator.call(
      conversation: other_conversation,
      decision: decision(title: "Solicitar cama externa", action_type: "request_extra_bed"),
      guest_message: external_message
    )
    external_title = external_task.title
    local_decision = decision(title: "Solicitar cama local", owner_task_id: external_task.id, action_type: "request_extra_bed")
    validation = AI::DecisionValidator.new(conversation: @conversation, decision: local_decision).call
    local_message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Quiero una cama adicional")

    local_task = OwnerTasks::Creator.call(conversation: @conversation, decision: local_decision, guest_message: local_message)

    assert validation.valid?
    assert_includes validation.warnings, "owner_task_reference_invalid"
    assert_not_equal external_task.id, local_task.id
    assert_equal external_title, external_task.reload.title
    assert_equal @account, local_task.account
  end

  test "a task reference from another conversation in the same account creates locally" do
    other_guest = @account.guests.create!(phone_number: "+59899008888", property: @property)
    other_conversation = other_guest.conversations.create!(property: @property)
    other_message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito una cama")
    other_task = OwnerTasks::Creator.call(
      conversation: other_conversation,
      decision: decision(title: "Solicitar cama en otra conversación", action_type: "request_extra_bed"),
      guest_message: other_message
    )
    local_decision = decision(title: "Solicitar cama adicional", owner_task_id: other_task.id, action_type: "request_extra_bed")
    validation = AI::DecisionValidator.new(conversation: @conversation, decision: local_decision).call
    local_message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Quiero una cama adicional")

    local_task = OwnerTasks::Creator.call(conversation: @conversation, decision: local_decision, guest_message: local_message)

    assert validation.valid?
    assert_includes validation.warnings, "owner_task_reference_invalid"
    assert_equal @conversation, local_task.conversation
    assert_not_equal other_task.id, local_task.id
    assert_equal "Solicitar cama en otra conversación", other_task.reload.title
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
