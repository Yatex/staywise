class PropertiesController < ApplicationController
  INITIAL_FAQ_DEFAULT_ROWS = 3
  INITIAL_APPLIANCE_GUIDE_DEFAULT_ROWS = 1
  INITIAL_RECOMMENDATION_DEFAULT_ROWS = 1
  PER_PAGE = 30

  before_action :set_property, only: [:show, :edit, :update, :destroy, :copy_content, :whatsapp_qr, :update_co_host]
  before_action :ensure_property_limit!, only: [:new, :create]

  def index
    @available_tags = readable_properties.pluck(:tags).flatten.compact_blank.uniq.sort
    @known_co_hosts = current_account.co_hosts.order(:name).to_a
    @available_co_hosts = readable_co_hosts.joins(:properties).distinct.order(:name).to_a
    @current_page = [params[:page].to_i, 1].max
    scope = filtered_properties.order(:name)
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @properties = scope.includes(:account, :co_host).limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE).to_a
  end

  def show
    @knowledge_blocks = @property.knowledge_blocks.order(:category, :title)
    @recommendations = @property.recommendations.order(:category, :name)
    @faqs = @property.faqs.order(:category, :question)
    @sensitive_data = @property_read_only ? [] : @property.sensitive_data.active.order(:kind)
    @new_questions = @property.alerts.unknown_questions.open.includes(:guest, :conversation).order(created_at: :desc).limit(10)
    @source_properties = current_account.properties.where.not(id: @property.id).order(:name)
    @whatsapp_link = Whatsapp::PropertyDeepLink.call(@property)
  end

  def new
    @source_properties = current_account.properties.order(:name)
    @property = current_account.properties.new
    set_co_host_fields
    @initial_faqs = blank_initial_faqs
    @initial_appliance_guides = blank_initial_appliance_guides
    @initial_recommendations = blank_initial_recommendations
    apply_property_template if params[:copy_from_id].present?
  end

  def create
    @property = current_account.properties.new(property_params)
    set_co_host_fields
    @initial_faqs = initial_faq_params
    @initial_appliance_guides = initial_appliance_guide_params
    @initial_recommendations = initial_recommendation_params

    if params[:preview_import].present?
      preview_property_import(:new)
      return
    end

    if invalid_initial_content?
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
    set_co_host_fields
    @initial_faqs = blank_initial_faqs
    @initial_appliance_guides = blank_initial_appliance_guides
    @initial_recommendations = blank_initial_recommendations
  end

  def update
    set_co_host_fields
    @initial_faqs = initial_faq_params
    @initial_appliance_guides = initial_appliance_guide_params
    @initial_recommendations = initial_recommendation_params

    if params[:preview_import].present?
      @property.assign_attributes(property_params)
      preview_property_import(:edit)
      return
    end

    if invalid_initial_content?
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
    @property.soft_delete!
    redirect_to properties_path, notice: "Propiedad eliminada."
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

  def update_co_host
    co_host = current_account.co_hosts.find_by(id: params[:co_host_id]) if params[:co_host_id].present?
    if params[:co_host_id].present? && co_host.blank?
      redirect_back fallback_location: properties_path, alert: t("ui.properties.co_host_not_found")
      return
    end

    submitted = params.fetch(:property, ActionController::Parameters.new)
    name = co_host&.name || submitted[:co_host_name]
    phone_number = co_host&.whatsapp_number || submitted[:co_host_phone_number]

    if Properties::CoHostAssignment.call(property: @property, name: name, phone_number: phone_number)
      redirect_back fallback_location: properties_path, notice: t("ui.properties.co_host_assigned", property: @property.display_name)
    else
      redirect_back fallback_location: properties_path, alert: @property.errors.full_messages.to_sentence
    end
  end

  private

  def filtered_properties
    scope = readable_properties
    scope = scope.where(status: params[:status]) if params[:status].present? && params[:status] != "all"
    scope = scope.tagged_with(params[:tag]) if params[:tag].present?
    if params[:co_host_id] == "none"
      scope = scope.where(co_host_id: nil)
    elsif params[:co_host_id].present?
      scope = scope.where(co_host_id: params[:co_host_id])
    end

    if params[:q].present?
      query = "%#{Property.sanitize_sql_like(params[:q].strip)}%"
      scope = scope.left_joins(:co_host).where(
        "properties.name ILIKE :query OR properties.internal_nickname ILIKE :query OR properties.address ILIKE :query OR co_hosts.name ILIKE :query OR co_hosts.whatsapp_number ILIKE :query",
        query: query
      )
    end

    scope
  end

  def set_property
    scope = if current_user.admin? && action_name.in?(%w[show whatsapp_qr])
      Property.all
    elsif action_name == "destroy"
      current_account.properties.with_deleted
    else
      current_account.properties
    end
    @property = scope.find(params[:id])
    @property_read_only = @property.account_id != current_account.id
  end

  def readable_properties
    current_account.properties
  end

  def readable_co_hosts
    current_account.co_hosts
  end

  def property_editable?(property)
    property.account_id == current_account.id
  end
  helper_method :property_editable?

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
      :checkout_instructions,
      :wifi_name,
      :wifi_password,
      :house_rules,
      :access_instructions,
      :parking_instructions,
      :emergency_information,
      :owner_contact_instructions,
      :owner_contact_phone,
      :ai_general_notes,
      :status,
      :tag_list,
      :ai_enabled
    )
  end

  def set_co_host_fields
    submitted = params.fetch(:property, ActionController::Parameters.new)
    @co_host_name = submitted.key?(:co_host_name) ? submitted[:co_host_name] : @property&.co_host&.name
    @co_host_phone_number = submitted.key?(:co_host_phone_number) ? submitted[:co_host_phone_number] : @property&.co_host&.whatsapp_number
  end

  def assign_co_host
    Properties::CoHostAssignment.call(
      property: @property,
      name: @co_host_name,
      phone_number: @co_host_phone_number
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

  def initial_appliance_guide_params(default: blank_initial_appliance_guides)
    permitted = params
      .fetch(:property, ActionController::Parameters.new)
      .permit(initial_appliance_guides: [:title, :content, :youtube_url])

    rows = Array(permitted[:initial_appliance_guides]).map do |row|
      row.to_h.slice("title", "content", "youtube_url")
    end

    rows.presence || default
  end

  def blank_initial_appliance_guides
    Array.new(INITIAL_APPLIANCE_GUIDE_DEFAULT_ROWS) { { "title" => "", "content" => "", "youtube_url" => "" } }
  end

  def initial_recommendation_params(default: blank_initial_recommendations)
    permitted = params
      .fetch(:property, ActionController::Parameters.new)
      .permit(
        initial_recommendations: [
          :name,
          :category,
          :description,
          :address,
          :distance_or_walking_time
        ]
      )

    rows = Array(permitted[:initial_recommendations]).map do |row|
      row.to_h.slice("name", "category", "description", "address", "distance_or_walking_time")
    end

    rows.presence || default
  end

  def blank_initial_recommendations
    Array.new(INITIAL_RECOMMENDATION_DEFAULT_ROWS) do
      {
        "name" => "",
        "category" => "",
        "description" => "",
        "address" => "",
        "distance_or_walking_time" => ""
      }
    end
  end

  def completed_initial_faqs
    Array(@initial_faqs).select do |row|
      row["question"].present? || row["answer"].present? || row["category"].present?
    end
  end

  def completed_initial_appliance_guides
    Array(@initial_appliance_guides).select { |row| row.values.any?(&:present?) }
  end

  def completed_initial_recommendations
    Array(@initial_recommendations).select { |row| row.values.any?(&:present?) }
  end

  def invalid_initial_content?
    invalid_faqs = completed_initial_faqs.any? do |row|
      row["question"].blank? || row["answer"].blank?
    end
    invalid_appliances = completed_initial_appliance_guides.any? do |row|
      row["title"].blank? || row["content"].blank?
    end
    invalid_recommendations = completed_initial_recommendations.any? do |row|
      row["name"].blank? || row["category"].blank?
    end

    @property.errors.add(:base, "Completá pregunta y respuesta en cada FAQ.") if invalid_faqs
    @property.errors.add(:base, "Completá nombre e instrucciones en cada electrodoméstico.") if invalid_appliances
    @property.errors.add(:base, "Completá nombre y categoría en cada recomendación.") if invalid_recommendations

    invalid_faqs || invalid_appliances || invalid_recommendations
  end

  def save_property_with_initial_faqs
    saved = false

    Property.transaction do
      saved = @property.save
      raise ActiveRecord::Rollback unless saved
      unless assign_co_host
        saved = false
        raise ActiveRecord::Rollback
      end

      completed_initial_faqs.each do |row|
        @property.faqs.create!(
          question: row["question"],
          answer: row["answer"],
          category: row["category"],
          active: true
        )
      end
      create_initial_appliance_guides!
      create_initial_recommendations!
    end

    saved
  end

  def update_property_with_initial_faqs
    saved = false

    Property.transaction do
      saved = @property.update(property_params)
      raise ActiveRecord::Rollback unless saved
      unless assign_co_host
        saved = false
        raise ActiveRecord::Rollback
      end

      create_initial_faqs!
      create_initial_appliance_guides!
      create_initial_recommendations!
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

  def create_initial_appliance_guides!
    completed_initial_appliance_guides.each do |row|
      @property.knowledge_blocks.create!(
        title: row["title"],
        category: "appliances",
        content: row["content"],
        youtube_url: row["youtube_url"],
        status: "active"
      )
    end
  end

  def create_initial_recommendations!
    completed_initial_recommendations.each do |row|
      @property.recommendations.create!(
        name: row["name"],
        category: row["category"],
        description: row["description"],
        address: row["address"],
        distance_or_walking_time: row["distance_or_walking_time"]
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
    @initial_appliance_guides = merge_imported_rows(
      result.appliance_guides,
      @initial_appliance_guides,
      keys: %w[title content youtube_url],
      identity_key: "title",
      blank_default: blank_initial_appliance_guides
    )
    @initial_recommendations = merge_imported_rows(
      result.recommendations,
      @initial_recommendations,
      keys: %w[name category description address distance_or_walking_time],
      identity_key: "name",
      blank_default: blank_initial_recommendations
    )
    @source_properties = current_account.properties.order(:name) if template == :new
    @property_import_fields = imported_content_labels(result)
    @property_import_notice = import_notice_for(result)
    flash.now[:notice] = @property_import_notice
    render template, status: :unprocessable_content
  rescue AI::PropertyImportService::ImportError => error
    @source_properties = current_account.properties.order(:name) if template == :new
    @initial_faqs = blank_initial_faqs if template == :new && Array(@initial_faqs).blank?
    @initial_appliance_guides = blank_initial_appliance_guides if Array(@initial_appliance_guides).blank?
    @initial_recommendations = blank_initial_recommendations if Array(@initial_recommendations).blank?
    @property_import_error = error.message
    flash.now[:alert] = @property_import_error
    render template, status: :unprocessable_content
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

  def merge_imported_rows(imported_rows, existing_rows, keys:, identity_key:, blank_default:)
    imported = Array(imported_rows).map { |row| row.to_h.stringify_keys.slice(*keys) }
      .select { |row| row[identity_key].present? }
    existing = Array(existing_rows).map { |row| row.to_h.stringify_keys.slice(*keys) }
    imported_identities = imported.map { |row| row[identity_key].to_s.downcase.strip }
    remaining_existing = existing.reject do |row|
      row.values.all?(&:blank?) || imported_identities.include?(row[identity_key].to_s.downcase.strip)
    end

    (imported + remaining_existing).presence || blank_default
  end

  def import_notice_for(result)
    faq_count = Array(result.faqs).count
    appliance_count = Array(result.appliance_guides).count
    recommendation_count = Array(result.recommendations).count
    fields = imported_content_labels(result)
    if fields.any?
      message = "Ayla leyó el archivo y completó: #{fields.to_sentence}. Revisá todo antes de guardar."
    else
      message = "Ayla leyó el archivo, pero no encontró datos claros para completar."
    end

    counts = []
    counts << "#{appliance_count} guía#{'s' if appliance_count != 1} de electrodomésticos" if appliance_count.positive?
    counts << "#{faq_count} FAQ#{'s' if faq_count != 1}" if faq_count.positive?
    counts << "#{recommendation_count} recomendación#{'es' if recommendation_count != 1}" if recommendation_count.positive?
    return message if counts.empty?

    "#{message} Preparó #{counts.to_sentence}."
  end

  def imported_content_labels(result)
    labels = imported_field_labels(result.property_attributes)
    labels << "electrodomésticos" if Array(result.appliance_guides).any?
    labels << "FAQs" if Array(result.faqs).any?
    labels << "recomendaciones locales" if Array(result.recommendations).any?
    labels
  end

  def imported_field_labels(attributes)
    labels = {
      "name" => "nombre",
      "address" => "dirección",
      "internal_nickname" => "alias interno",
      "check_in_time" => "check-in",
      "checkout_time" => "checkout",
      "checkout_instructions" => "instrucciones de salida",
      "wifi_name" => "nombre de WiFi",
      "wifi_password" => "contraseña de WiFi",
      "house_rules" => "reglas",
      "access_instructions" => "acceso",
      "parking_instructions" => "estacionamiento",
      "emergency_information" => "emergencias",
      "owner_contact_instructions" => "cuándo consultar al propietario",
      "ai_general_notes" => "notas útiles",
      "tag_list" => "etiquetas"
    }

    attributes.to_h.filter_map { |key, value| labels[key.to_s] if value.present? }
  end
end
