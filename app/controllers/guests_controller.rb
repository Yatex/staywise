class GuestsController < ApplicationController
  def index
    @guests = current_account.guests.includes(:property).order(updated_at: :desc)
  end

  def show
    @guest = current_account.guests.includes(:property, conversations: :property).find(params[:id])
    @conversations = @guest.conversations.includes(:property).recent
    @alerts = @guest.alerts.includes(:property).order(created_at: :desc)
  end
end
