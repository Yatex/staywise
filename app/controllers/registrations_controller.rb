class RegistrationsController < ApplicationController
  skip_before_action :require_authentication

  def new
    @account = Account.new
    @user = User.new
  end

  def create
    Account.transaction do
      @account = Account.create!(name: registration_params[:account_name])
      @user = @account.users.create!(
        name: registration_params[:name],
        email: registration_params[:email],
        password: registration_params[:password],
        password_confirmation: registration_params[:password_confirmation]
      )
      @account.subscriptions.create!(plan: "starter", status: "trialing", trial_ends_at: 14.days.from_now)
    end

    sign_in(@user)
    redirect_to dashboard_path, notice: "Welcome to Staywise."
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
      :password_confirmation
    )
  end
end
