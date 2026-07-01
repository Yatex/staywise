class AddEmailVerificationToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :email_verified_at, :datetime
    add_column :users, :email_verification_token, :string
    add_column :users, :email_verification_sent_at, :datetime

    add_index :users, :email_verification_token, unique: true

    reversible do |dir|
      dir.up do
        execute "UPDATE users SET email_verified_at = CURRENT_TIMESTAMP"
      end
    end
  end
end
