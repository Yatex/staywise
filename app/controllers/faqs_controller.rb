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
      @property.faqs.new(source.attributes.slice("question", "answer", "category", "active"))
    else
      @property.faqs.new(active: true)
    end
  end

  def create
    @faq = @property.faqs.new(faq_params)

    if @faq.save
      redirect_to property_path(@property), notice: "FAQ saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @faq.update(faq_params)
      redirect_to property_path(@property), notice: "FAQ updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @faq.destroy
    redirect_to property_path(@property), notice: "FAQ removed."
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

  def faq_params
    params.require(:faq).permit(:question, :answer, :category, :active)
  end
end
