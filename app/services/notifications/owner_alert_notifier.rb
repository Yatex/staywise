module Notifications
  class OwnerAlertNotifier
    def self.call(alert)
      new(alert).call
    end

    def initialize(alert)
      @alert = alert
    end

    def call
      @alert.property.account.users.find_each do |user|
        EmailService.deliver(
          to: user.email,
          subject: "[Staywise] Alerta urgente de huésped: #{@alert.title}",
          html: email_html
        )
      end
    end

    private

    def email_html
      <<~HTML
        <h1>#{ERB::Util.html_escape(@alert.title)}</h1>
        <p><strong>Propiedad:</strong> #{ERB::Util.html_escape(@alert.property.display_name)}</p>
        <p><strong>Huésped:</strong> #{ERB::Util.html_escape(@alert.guest&.display_name || "Huésped desconocido")}</p>
        <p>#{ERB::Util.html_escape(@alert.description)}</p>
        <p><strong>Acción sugerida:</strong> #{ERB::Util.html_escape(@alert.ai_suggested_action)}</p>
      HTML
    end
  end
end
