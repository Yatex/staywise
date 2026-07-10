class ExtendGuestRequestsForApprovalAndUpdates < ActiveRecord::Migration[7.1]
  def change
    add_column :guest_requests, :requires_owner_approval, :boolean, null: false, default: false
    add_column :guest_requests, :structured_details, :jsonb, null: false, default: {}
    add_index :guest_requests, :message_id, unique: true, name: "index_guest_requests_on_message_id_unique"
  end
end
