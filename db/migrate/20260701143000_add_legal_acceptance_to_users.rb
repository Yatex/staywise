class AddLegalAcceptanceToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :terms_accepted_at, :datetime
    add_column :users, :privacy_accepted_at, :datetime
    add_column :users, :terms_version, :string
    add_column :users, :privacy_version, :string
    add_column :users, :legal_acceptance_ip, :string
    add_column :users, :legal_acceptance_user_agent, :text
  end
end
