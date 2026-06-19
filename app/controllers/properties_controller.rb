class PropertiesController < ApplicationController
  before_action :set_property, only: [:show, :edit, :update, :destroy, :copy_content, :whatsapp_qr]
  before_action :ensure_property_limit!, only: [:new, :create]

  def index
    @available_tags = current_account.properties.pluck(:tags).flatten.compact_blank.uniq.sort
    @properties = filtered_properties.includes(:knowledge_blocks, :recommendations, :alerts).order(:name)
  end

  def show
    @knowledge_blocks = @property.knowledge_blocks.order(:category, :title)
    @recommendations = @property.recommendations.order(:category, :name)
    @faqs = @property.faqs.order(:category, :question)
    @alerts = @property.alerts.includes(:guest).open.order(created_at: :desc).limit(10)
    @conversations = @property.conversations.includes(:guest).recent.limit(10)
    @source_properties = current_account.properties.where.not(id: @property.id).order(:name)
    @whatsapp_link = Whatsapp::PropertyDeepLink.call(@property)
  end

  def new
    @source_properties = current_account.properties.order(:name)
    @property = current_account.properties.new
    apply_property_template if params[:copy_from_id].present?
  end

  def create
    @property = current_account.properties.new(property_params)

    if @property.save
      redirect_to @property, notice: "Propiedad creada."
    else
      @source_properties = current_account.properties.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @property.update(property_params)
      redirect_to @property, notice: "Propiedad actualizada."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @property.update(status: "archived")
    redirect_to properties_path, notice: "Propiedad archivada."
  end

  def copy_content
    source = current_account.properties.find(params[:source_property_id])
    copied = Properties::ContentCopier.new(
      source: source,
      target: @property,
      content_types: params.fetch(:content_types, [])
    ).call

    if copied.blank?
      redirect_to property_path(@property), alert: "Elegí al menos un tipo de contenido para copiar."
      return
    end

    redirect_to property_path(@property), notice: "Contenido copiado desde #{source.display_name}."
  rescue ActiveRecord::RecordNotFound
    redirect_to property_path(@property), alert: "Elegí una propiedad desde donde copiar."
  end

  def whatsapp_qr
    svg = Whatsapp::PropertyQrCode.svg_for(@property)
    disposition = params[:download].present? ? "attachment" : "inline"

    send_data svg,
      type: "image/svg+xml",
      disposition: disposition,
      filename: "#{@property.display_name.parameterize.presence || "property"}-whatsapp-qr.svg"
  end

  private

  def filtered_properties
    scope = current_account.properties
    scope = scope.where(status: params[:status]) if params[:status].present? && params[:status] != "all"
    scope = scope.tagged_with(params[:tag]) if params[:tag].present?

    if params[:q].present?
      query = "%#{Property.sanitize_sql_like(params[:q].strip)}%"
      scope = scope.where(
        "properties.name ILIKE :query OR properties.internal_nickname ILIKE :query OR properties.address ILIKE :query",
        query: query
      )
    end

    scope
  end

  def set_property
    @property = current_account.properties.find(params[:id])
  end

  def apply_property_template
    source = current_account.properties.find_by(id: params[:copy_from_id])
    return if source.blank?

    @property.assign_attributes(source.copyable_settings)
    @property.name = nil
    @property.address = nil
    @property.internal_nickname = nil
  end

  def property_params
    params.require(:property).permit(
      :name,
      :address,
      :internal_nickname,
      :check_in_time,
      :checkout_time,
      :wifi_name,
      :wifi_password,
      :house_rules,
      :access_instructions,
      :parking_instructions,
      :emergency_information,
      :owner_contact_instructions,
      :ai_general_notes,
      :status,
      :tag_list,
      :ai_enabled
    )
  end
end
