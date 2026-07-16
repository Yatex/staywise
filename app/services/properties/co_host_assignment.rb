module Properties
  class CoHostAssignment
    def self.call(property:, name:, phone_number:)
      new(property: property, name: name, phone_number: phone_number).call
    end

    def initialize(property:, name:, phone_number:)
      @property = property
      @name = name.to_s.strip
      @phone_number = Whatsapp::HostActor.normalize(phone_number)
    end

    def call
      return remove_assignment if @name.blank? && @phone_number.blank?

      if @name.blank? || @phone_number.blank?
        @property.errors.add(:co_host, "requiere nombre y teléfono de WhatsApp")
        return false
      end
      if @phone_number == Whatsapp::HostActor.normalize(@property.account.owner_whatsapp_number)
        @property.errors.add(:co_host, "no puede usar el mismo WhatsApp que el anfitrión principal")
        return false
      end

      co_host = CoHost.find_or_initialize_by(whatsapp_number: @phone_number)
      if co_host.persisted? && co_host.account_id != @property.account_id
        @property.errors.add(:co_host, "ya está asociado a otro anfitrión y el número sería ambiguo")
        return false
      end
      co_host.assign_attributes(account: @property.account, name: @name)
      unless co_host.save
        co_host.errors.full_messages.each { |message| @property.errors.add(:co_host, message) }
        return false
      end

      @property.update!(co_host: co_host)
      true
    end

    private

    def remove_assignment
      @property.update!(co_host: nil)
      true
    end
  end
end
