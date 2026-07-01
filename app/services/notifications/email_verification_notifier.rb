module Notifications
  class EmailVerificationNotifier
    def self.call(user)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      @user.regenerate_email_verification_token if @user.email_verification_token.blank?
      @user.update_column(:email_verification_sent_at, Time.current)

      EmailService.deliver(
        to: @user.email,
        subject: "Confirmá tu email en Ayla Manager",
        html: html
      )
    end

    private

    def html
      url = Rails.application.routes.url_helpers.verify_email_url(token: @user.email_verification_token, host: app_host)

      <<~HTML
        <h1>Confirmá tu email</h1>
        <p>Hola #{@user.name.presence || @user.email},</p>
        <p>Para activar tu cuenta de Ayla Manager, confirmá tu email desde este link:</p>
        <p><a href="#{ERB::Util.html_escape(url)}">Confirmar email</a></p>
        <p>Si no creaste esta cuenta, podés ignorar este mensaje.</p>
      HTML
    end

    def app_host
      ENV["APP_HOST"].presence || "http://localhost:3000"
    end
  end
end
