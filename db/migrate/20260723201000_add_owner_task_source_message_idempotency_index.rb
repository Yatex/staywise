class AddOwnerTaskSourceMessageIdempotencyIndex < ActiveRecord::Migration[7.1]
  def change
    add_index :guest_requests,
      "(metadata->>'source_guest_message_id')",
      unique: true,
      where: "metadata ? 'source_guest_message_id'",
      name: "index_owner_tasks_on_source_guest_message_id"
  end
end
