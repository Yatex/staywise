module Whatsapp
  class HostActor
    attr_reader :account, :role, :phone_number, :co_host

    def self.owner(account)
      new(account: account, role: "owner", phone_number: account.owner_whatsapp_number)
    end

    def self.co_host(co_host)
      new(account: co_host.account, role: "co_host", phone_number: co_host.whatsapp_number, co_host: co_host)
    end

    def self.resolve(phone_number)
      phone = normalize(phone_number)
      owner_accounts = Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: phone).to_a
      co_hosts = CoHost.joins(:properties).where(whatsapp_number: phone).distinct.includes(:account).to_a
      actors = owner_accounts.map { |account| owner(account) } + co_hosts.map { |co_host| self.co_host(co_host) }
      raise ActiveRecord::RecordNotFound, "WhatsApp host identity is ambiguous" unless actors.one?

      actors.first
    end

    def self.for_property(property)
      actors = []
      actors << owner(property.account) if property.account.owner_whatsapp_configured?
      actors << co_host(property.co_host) if property.co_host.present?
      actors.uniq { |actor| normalize(actor.phone_number) }
    end

    def self.authorized_phone?(phone_number)
      phone = normalize(phone_number)
      Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: phone).exists? ||
        CoHost.joins(:properties).where(whatsapp_number: phone).exists?
    end

    def self.normalize(phone_number)
      phone_number.to_s.gsub(/\Awhatsapp:/, "").gsub(/[^\d+]/, "").strip
    end

    def initialize(account:, role:, phone_number:, co_host: nil)
      @account = account
      @role = role
      @phone_number = self.class.normalize(phone_number)
      @co_host = co_host
    end

    def id
      owner? ? account.id : co_host.id
    end

    def type
      owner? ? "Account" : "CoHost"
    end

    def owner?
      role == "owner"
    end

    def property_ids
      @property_ids ||= owner? ? account.properties.pluck(:id) : co_host.properties.pluck(:id)
    end

    def can_manage_property?(property)
      property.account_id == account.id && (owner? || property.co_host_id == co_host.id)
    end
  end
end
