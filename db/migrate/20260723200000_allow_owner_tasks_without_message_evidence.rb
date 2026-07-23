class AllowOwnerTasksWithoutMessageEvidence < ActiveRecord::Migration[7.1]
  def change
    change_column_null :guest_requests, :message_id, true
    change_column_null :guest_requests, :description, true
  end
end
