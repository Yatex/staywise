class SimplifyOwnerTaskAndAlertStatuses < ActiveRecord::Migration[7.1]
  def up
    execute "UPDATE guest_requests SET status = 'open' WHERE status IN ('pending', 'in_progress')"
    execute "UPDATE guest_requests SET status = 'resolved' WHERE status IN ('rejected', 'cancelled')"
    execute "UPDATE alerts SET status = 'open' WHERE status = 'in_progress'"
    execute "UPDATE alerts SET status = 'resolved' WHERE status = 'dismissed'"

    change_column_default :guest_requests, :status, from: "pending", to: "open"
  end

  def down
    change_column_default :guest_requests, :status, from: "open", to: "pending"
    execute "UPDATE guest_requests SET status = 'pending' WHERE status = 'open'"
  end
end
