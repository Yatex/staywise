class FaqsController < ApplicationController
  before_action :set_property
  before_action :set_faq, only: [:edit, :update, :destroy]
  before_action :set_source_faqs, only: [:new, :create]

  def index
    @faqs = @property.faqs.order(:category, :question)
  end

  def new
    source = source_faqs.find_by(id: params[:source_id])
    @faq = if source
      @property.faqs.new(source.attributes.slice("question", "answer", "category", "active", "status", "source_type"))
    else
      @property.faqs.new(active: true, status: "approved", source_type: "manual")
    end
  end

  def create
    @faq = @property.faqs.new(faq_params)

    if @faq.save
      redirect_to property_path(@property), notice: "FAQ guardada."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def bulk_new
    @faq = @property.faqs.new(active: true, status: "approved", source_type: "manual")
    load_bulk_properties
  end

  def bulk_create
    @faq = @property.faqs.new(faq_params.merge(source_type: "manual"))
    load_bulk_properties
    selected_properties = @available_properties.where(id: @selected_property_ids)

    if selected_properties.none?
      @faq.errors.add(:base, "Seleccioná al menos una propiedad.")
      return render :bulk_new, status: :unprocessable_entity
    end

    unless @faq.valid?
      return render :bulk_new, status: :unprocessable_entity
    end

    created_count, skipped_count = create_bulk_faqs(selected_properties)
    notice = "FAQ agregada en #{created_count} #{created_count == 1 ? "propiedad" : "propiedades"}."
    if skipped_count.positive?
      notice += " Se #{skipped_count == 1 ? "omitió 1 propiedad" : "omitieron #{skipped_count} propiedades"} porque ya tenían la misma pregunta."
    end

    redirect_to property_path(@property, anchor: "faqs"), notice: notice
  rescue ActiveRecord::RecordInvalid => error
    @faq.errors.add(:base, error.record.errors.full_messages.to_sentence)
    render :bulk_new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @faq.update(faq_params)
      redirect_to property_path(@property), notice: "FAQ actualizada."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @faq.destroy
    redirect_to property_path(@property), notice: "FAQ eliminada."
  end

  private

  def set_property
    @property = current_account.properties.find(params[:property_id])
  end

  def set_faq
    @faq = @property.faqs.find(params[:id])
  end

  def set_source_faqs
    @source_faqs = source_faqs.order("properties.name ASC", "faqs.question ASC")
  end

  def source_faqs
    Faq.joins(:property)
      .where(properties: { account_id: current_account.id })
      .where.not(property_id: @property.id)
      .includes(:property)
  end

  def load_bulk_properties
    @available_properties = current_account.properties.order(:name)
    @selected_property_ids = Array(params[:property_ids]).map(&:to_s)
    @selected_property_ids = [@property.id.to_s] if @selected_property_ids.empty? && request.get?
  end

  def create_bulk_faqs(properties)
    normalized_question = normalize_question(@faq.question)
    property_ids = properties.ids
    existing_property_ids = Faq.where(property_id: property_ids).pluck(:property_id, :question).filter_map do |property_id, question|
      property_id if normalize_question(question) == normalized_question
    end.to_set
    operation_id = SecureRandom.uuid
    attributes = faq_params.to_h.symbolize_keys.merge(
      source_type: "manual",
      metadata: {
        "bulk_created" => true,
        "bulk_operation_id" => operation_id,
        "bulk_source_property_id" => @property.id
      }
    )
    created_count = 0

    Faq.transaction do
      properties.each do |property|
        next if existing_property_ids.include?(property.id)

        property.faqs.create!(attributes)
        created_count += 1
      end
    end

    [created_count, existing_property_ids.size]
  end

  def normalize_question(question)
    question.to_s.unicode_normalize(:nfkc).squish.downcase
  end

  def faq_params
    params.require(:faq).permit(:question, :answer, :category, :active, :status, :source_type)
  end
end
