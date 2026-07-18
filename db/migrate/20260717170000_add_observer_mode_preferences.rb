class AddObserverModePreferences < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :observer_mode_enabled, :boolean, null: false, default: false
    add_column :accounts, :observer_mode_activated_at, :datetime
    add_column :co_hosts, :observer_mode_enabled, :boolean, null: false, default: false
    add_column :co_hosts, :observer_mode_activated_at, :datetime
  end
end
