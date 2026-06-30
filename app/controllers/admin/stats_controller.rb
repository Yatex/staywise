module Admin
  class StatsController < BaseController
    def index
      @total_users = User.count
      @admin_users = User.where(role: "admin").count
      @owner_users = User.where(role: "owner").count
      @member_users = User.where(role: "member").count

      @total_accounts = Account.count
      @total_properties = Property.count
      @total_guests = Guest.count
      @total_conversations = Conversation.count
      @active_conversations = Conversation.where(status: "active").count
      @open_alerts = Alert.open.count
      @ai_messages = Message.where(sender: "ai").count
      @open_operational_errors = OperationalError.open.count
      @critical_operational_errors = OperationalError.open.where(severity: "critical").count

      @subscriptions_by_status = Subscription.group(:status).count
      @subscriptions_by_plan = Subscription.group(:plan).count
      @paying_subscriptions = Subscription.where(status: "active").count
      @trialing_subscriptions = Subscription.where(status: "trialing").count
      @past_due_subscriptions = Subscription.where(status: "past_due").count
      @canceled_subscriptions = Subscription.where(status: "canceled").count
      @paying_accounts = Account.joins(:subscriptions).where(subscriptions: { status: "active" }).distinct.count

      @alerts_by_type = Alert.group(:alert_type).order(Arel.sql("COUNT(*) DESC")).count
      @recent_signups = User.includes(:account).order(created_at: :desc).limit(8)
      @recent_billing_events = BillingEvent.includes(:account).order(created_at: :desc).limit(8)
      @recent_operational_errors = OperationalError.includes(:account, :property).open.recent.limit(8)
    end
  end
end
