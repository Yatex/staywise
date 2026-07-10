class GuestRequestsController < ApplicationController
  PER_PAGE = 30

  def index
    scope = scoped_guest_requests.includes(:guest, :property, :conversation).pending_first
    scope = scope.where(property_id: params[:property_id]) if params[:property_id].present?
    scope = scope.where(status: params[:status]) if params[:status].present?

    @properties = current_account.properties.active.order(:name)
    @current_page = [params[:page].to_i, 1].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @guest_requests = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
  end

  def show
    @guest_request = scoped_guest_requests.includes(:guest, :property, :conversation, :message).find(params[:id])
  end

  def update
    @guest_request = scoped_guest_requests.find(params[:id])

    if @guest_request.update(guest_request_params)
      redirect_back fallback_location: guest_request_path(@guest_request), notice: "Pedido actualizado."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def scoped_guest_requests
    current_account.guest_requests
  end

  def guest_request_params
    params.require(:guest_request).permit(:status, :priority)
  end
end
