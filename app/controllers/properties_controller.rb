class PropertiesController < ApplicationController
  INITIAL_FAQ_DEFAULT_ROWS = 3

  before_action :set_property, only: [:show, :edit, :update, :destroy, :copy_content, :whatsapp_qr]
  before_action :ensure_property_limit!, only: [:new, :create]

  def index
    @available_tags = current_account.properties.pluck(:tags).flatten.compact_blank.uniq.sort
    @properties = filtered_properties.includes(:knowledge_blocks, :recommendations, :alerts).order(:name)
  end

  def show
    @appliance_guides = @property.knowledge_blocks.where(category: "appliances").order(:title)
    @knowledge_blocks = @property.knowledge_blocks.where.not(category: "appliances").order(:category, :title)
    @recommendations = @property.recommendations.order(:category, :name)
    @faqs = @property.faqs.order(:category, :question)
    @new_questions = @property.alerts.unknown_questions.open.includes(:guest, :conversation).order(created_at: :desc).limit(10)
    @alerts = @property.alerts.operational.open.includes(:guest).order(created_at: :desc).limit(10)
    @conversations = @property.conversations.includes(:guest).recent.limit(10)
    @source_properties = current_account.properties.where.not(id: @property.id).order(:name)
    @whatsapp_link = Whatsapp::PropertyDeepLink.call(@property)
  end

  def new
    @source_properties = current_account.properties.order(:name)
    @property = current_account.properties.new
    @initial_faqs = blank_initial_faqs
    apply_property_template if params[:copy_from_id].present?
  end

  def create
    @property = current_account.properties.new(property_params)
    @initial_faqs = initial_faq_params

    if params[:preview_import].present?
      preview_property_import(:new)
      return
    end

    if invalid_initial_faqs?
      @source_properties = current_account.properties.order(:name)
      render :new, status: :unprocessable_entity
      return
    end

    if save_property_with_initial_faqs
      redirect_to @property, notice: "Propiedad creada."
    else
      @source_properties = current_account.properties.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @initial_faqs = []
  end

  def update
    @initial_faqs = initial_faq_params(default: [])

    if params[:preview_import].present?
      @property.assign_attributes(property_params)
      preview_property_import(:edit)
      return
    end

    if invalid_initial_faqs?
      render :edit, status: :unprocessable_entity
      return
    end

    if update_property_with_initial_faqs
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

  def initial_faq_params(default: blank_initial_faqs)
    permitted = params
      .fetch(:property, ActionController::Parameters.new)
      .permit(initial_faqs: [:question, :answer, :category])

    rows = Array(permitted[:initial_faqs]).map do |row|
      row.to_h.slice("question", "answer", "category")
    end

    rows.presence || default
  end

  def blank_initial_faqs
    Array.new(INITIAL_FAQ_DEFAULT_ROWS) { { "question" => "", "answer" => "", "category" => "" } }
  end

  def completed_initial_faqs
    Array(@initial_faqs).select do |row|
      row["question"].present? || row["answer"].present? || row["category"].present?
    end
  end

  def invalid_initial_faqs?
    invalid = completed_initial_faqs.any? do |row|
      row["question"].blank? || row["answer"].blank?
    end

    @property.errors.add(:base, "Completá pregunta y respuesta en cada FAQ inicial.") if invalid
    invalid
  end

  def save_property_with_initial_faqs
    saved = false

    Property.transaction do
      saved = @property.save
      raise ActiveRecord::Rollback unless saved

      completed_initial_faqs.each do |row|
        @property.faqs.create!(
          question: row["question"],
          answer: row["answer"],
          category: row["category"],
          active: true
        )
      end
    end

    saved
  end

  def update_property_with_initial_faqs
    saved = false

    Property.transaction do
      saved = @property.update(property_params)
      raise ActiveRecord::Rollback unless saved

      create_initial_faqs!
    end

    saved
  end

  def create_initial_faqs!
    completed_initial_faqs.each do |row|
      @property.faqs.create!(
        question: row["question"],
        answer: row["answer"],
        category: row["category"],
        active: true
      )
    end
  end

  def preview_property_import(template)
    result = AI::PropertyImportService.call(
      account: current_account,
      property: @property,
      upload: params.dig(:property_import, :file)
    )

    @property.assign_attributes(result.property_attributes)
    @initial_faqs = merge_imported_faqs(result.faqs, @initial_faqs)
    @source_properties = current_account.properties.order(:name) if template == :new
    flash.now[:notice] = import_notice_for(result)
    render template, status: :ok
  rescue AI::PropertyImportService::ImportError => error
    @source_properties = current_account.properties.order(:name) if template == :new
    @initial_faqs = blank_initial_faqs if template == :new && Array(@initial_faqs).blank?
    flash.now[:alert] = error.message
    render template, status: :unprocessable_entity
  end

  def merge_imported_faqs(imported_faqs, existing_faqs)
    imported = Array(imported_faqs).map { |row| stringify_faq_row(row) }.select { |row| row["question"].present? || row["answer"].present? }
    existing = Array(existing_faqs).map { |row| stringify_faq_row(row) }
    imported_questions = imported.map { |row| row["question"].to_s.downcase.strip }
    remaining_existing = existing.reject do |row|
      row.values.all?(&:blank?) || imported_questions.include?(row["question"].to_s.downcase.strip)
    end

    combined = imported + remaining_existing
    combined.presence || (@property.persisted? ? [] : blank_initial_faqs)
  end

  def stringify_faq_row(row)
    row.to_h.stringify_keys.slice("question", "answer", "category")
  end

  def import_notice_for(result)
    count = result.faqs.count
    message = "Ayla leyó el archivo y completó los campos que pudo detectar. Revisá todo antes de guardar."
    return message if count.zero?

    "#{message} También preparó #{count} FAQ#{'s' if count != 1} para agregar."
  end
end
