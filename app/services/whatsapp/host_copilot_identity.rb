module Whatsapp
  class HostCopilotIdentity
    attr_reader :account, :user, :role, :phone_number, :co_host

    def self.resolve(phone_number)
      phone = HostActor.normalize(phone_number)
      owner_accounts = Account.where(owner_whatsapp_number: phone).to_a
      co_hosts = CoHost.joins(:properties).merge(Property.active).where(whatsapp_number: phone).distinct.includes(:account).to_a
      candidates = owner_accounts.map { |account| ["owner", account, nil] } +
        co_hosts.map { |co_host| ["co_host", co_host.account, co_host] }
      return nil if candidates.empty?

      raise ActiveRecord::RecordNotFound, "WhatsApp host identity is ambiguous" unless candidates.one?

      role, account, co_host = candidates.first
      user = account.users.where(role: %w[owner admin]).order(Arel.sql("CASE role WHEN 'owner' THEN 0 ELSE 1 END"), :id).first
      return nil unless user

      new(account: account, user: user, role: role, phone_number: phone, co_host: co_host)
    end

    def initialize(account:, user:, role:, phone_number:, co_host: nil)
      @account = account
      @user = user
      @role = role
      @phone_number = HostActor.normalize(phone_number)
      @co_host = co_host
    end

    def available_properties
      scope = account.properties.active
      role == "co_host" ? scope.where(co_host_id: co_host.id) : scope
    end

    def collision_with_guest?
      Guest.where(phone_number: phone_number).exists?
    end
  end
end
