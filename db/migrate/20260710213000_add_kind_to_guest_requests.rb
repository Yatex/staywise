class AddKindToGuestRequests < ActiveRecord::Migration[7.1]
  def up
    add_column :guest_requests, :kind, :string, null: false, default: "request"
    add_index :guest_requests, [:account_id, :kind, :status], name: "index_owner_tasks_on_account_kind_status"
    add_check_constraint :guest_requests, "kind IN ('request', 'inquiry')", name: "guest_requests_kind_check"
  end

  def down
    remove_check_constraint :guest_requests, name: "guest_requests_kind_check"
    remove_index :guest_requests, name: "index_owner_tasks_on_account_kind_status"
    remove_column :guest_requests, :kind
  end
end
