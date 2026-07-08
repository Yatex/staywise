class RealignSubscriptionPlanIds < ActiveRecord::Migration[7.1]
  def up
    execute "UPDATE subscriptions SET plan = 'legacy_scale' WHERE plan = 'pro'"
    execute "UPDATE subscriptions SET plan = 'pro' WHERE plan = 'business'"
    execute "UPDATE subscriptions SET plan = 'scale' WHERE plan = 'legacy_scale'"
  end

  def down
    execute "UPDATE subscriptions SET plan = 'legacy_pro' WHERE plan = 'pro'"
    execute "UPDATE subscriptions SET plan = 'business' WHERE plan = 'legacy_pro'"
    execute "UPDATE subscriptions SET plan = 'pro' WHERE plan = 'scale'"
  end
end
