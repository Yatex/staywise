class CheckoutEventsController < ApplicationController
  PER_PAGE = 30

  def index
    scope = scoped_checkout_events
      .includes(:guest, :property, :conversation, :source_message)
      .order(checked_out_at: :desc, id: :desc)
    scope = scope.pending if params[:status] == "pending"
    scope = scope.where(status: "seen") if params[:status] == "seen"

    @pending_count = scoped_checkout_events.pending.count
    @seen_count = scoped_checkout_events.where(status: "seen").count
    @current_page = [params[:page].to_i, 1].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @checkout_events = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
  end

  def show
    @checkout_event = scoped_checkout_events
      .includes(:guest, :property, :conversation, :source_message)
      .find(params[:id])
  end

  def update
    checkout_event = scoped_checkout_events.find(params[:id])
    checkout_event.mark_seen!

    redirect_to checkout_event_path(checkout_event), notice: "Salida marcada como vista."
  end

  private

  def scoped_checkout_events
    current_account.checkout_events
  end
end
