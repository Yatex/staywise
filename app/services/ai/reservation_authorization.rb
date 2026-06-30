module AI
  class ReservationAuthorization
    ACCESS_WINDOW_DAYS_BEFORE_CHECKIN = 1

    def initialize(guest:, property:, now: Time.current)
      @guest = guest
      @property = property
      @now = now
    end

    def reservation_status
      return "unknown" if @guest.blank? || @guest.check_in_date.blank? || @guest.checkout_date.blank?
      return "wrong_property" if @guest.property.present? && @guest.property != @property

      today = @now.to_date
      return "pre_arrival" if today < @guest.check_in_date
      return "checked_in" if today <= @guest.checkout_date

      "post_checkout"
    end

    def sensitive_access_authorized?
      return false if @guest.blank? || @guest.property != @property
      return true if @guest.check_in_date.blank? && @guest.checkout_date.blank?
      return false if @guest.check_in_date.blank? || @guest.checkout_date.blank?

      today = @now.to_date
      access_start = @guest.check_in_date - ACCESS_WINDOW_DAYS_BEFORE_CHECKIN.days
      today >= access_start && today <= @guest.checkout_date
    end
  end
end
