class RegistrationsController < ApplicationController
  skip_before_action :require_authentication

  def new
    @account = Account.new
    @user = User.new
  end

  def create
    unless legal_acceptance?
      @account = Account.new(name: registration_params[:account_name])
      @user = User.new(email: registration_params[:email], name: registration_params[:name])
      @signup_error = t("ui.auth.legal_required")
      return render :new, status: :unprocessable_entity
    end

    Account.transaction do
      @account = Account.create!(name: registration_params[:account_name])
      @user = @account.users.build(
        name: registration_params[:name],
        email: registration_params[:email],
        password: registration_params[:password],
        password_confirmation: registration_params[:password_confirmation]
      )
      @user.accept_legal_documents!(request: request)
      @user.save!
      @account.subscriptions.create!(plan: "starter", status: "trialing", trial_ends_at: 14.days.from_now)
    end

    Notifications::EmailVerificationNotifier.call(@user)
    redirect_to login_path, notice: "Cuenta creada. Te enviamos un email para confirmar tu cuenta antes de ingresar."
  rescue ActiveRecord::RecordInvalid => error
    @account ||= Account.new(name: registration_params[:account_name])
    @user ||= User.new(email: registration_params[:email], name: registration_params[:name])
    @signup_error = error.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
  end

  private

  def registration_params
    params.require(:registration).permit(
      :account_name,
      :name,
      :email,
      :password,
      :password_confirmation,
      :legal_acceptance
    )
  end

  def legal_acceptance?
    ActiveModel::Type::Boolean.new.cast(registration_params[:legal_acceptance])
  end
end
