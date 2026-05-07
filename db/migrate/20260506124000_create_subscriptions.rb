class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.references :account, null: false, foreign_key: true
      t.string :plan, null: false, default: "starter"
      t.string :status, null: false, default: "incomplete"
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.datetime :current_period_end
      t.datetime :trial_ends_at

      t.timestamps
    end

    add_index :subscriptions, :stripe_customer_id
    add_index :subscriptions, :stripe_subscription_id, unique: true
  end
end
