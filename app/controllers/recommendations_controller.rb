class RecommendationsController < ApplicationController
  before_action :set_property, except: [:index]
  before_action :set_recommendation, only: [:edit, :update, :destroy]
  before_action :set_source_recommendations, only: [:new, :create]

  def index
    @recommendations = Recommendation.joins(:property)
      .where(properties: { account_id: current_account.id })
      .includes(:property)
      .order(:category, :name)
  end

  def new
    source = source_recommendations.find_by(id: params[:source_id])
    @recommendation = if source
      @property.recommendations.new(
        source.attributes.slice(
          "name",
          "category",
          "description",
          "address",
          "google_maps_url",
          "website_url",
          "phone_number",
          "owner_note",
          "distance_or_walking_time"
        )
      )
    else
      @property.recommendations.new
    end
  end

  def create
    @recommendation = @property.recommendations.new(recommendation_params)

    if @recommendation.save
      redirect_to property_path(@property), notice: "Recomendación guardada."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @recommendation.update(recommendation_params)
      redirect_to property_path(@property), notice: "Recomendación actualizada."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @recommendation.destroy
    redirect_to property_path(@property), notice: "Recomendación eliminada."
  end

  private

  def set_property
    @property = current_account.properties.find(params[:property_id])
  end

  def set_recommendation
    @recommendation = @property.recommendations.find(params[:id])
  end

  def set_source_recommendations
    @source_recommendations = source_recommendations.order("properties.name ASC", "recommendations.name ASC")
  end

  def source_recommendations
    Recommendation.joins(:property)
      .where(properties: { account_id: current_account.id })
      .where.not(property_id: @property.id)
      .includes(:property)
  end

  def recommendation_params
    params.require(:recommendation).permit(
      :name,
      :category,
      :description,
      :address,
      :google_maps_url,
      :website_url,
      :phone_number,
      :owner_note,
      :distance_or_walking_time
    )
  end
end
