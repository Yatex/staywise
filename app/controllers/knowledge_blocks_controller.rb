class KnowledgeBlocksController < ApplicationController
  before_action :set_property
  before_action :set_knowledge_block, only: [:edit, :update, :destroy]
  before_action :set_source_knowledge_blocks, only: [:new, :create]

  def index
    @knowledge_blocks = @property.knowledge_blocks.order(:category, :title)
  end

  def new
    source = source_knowledge_blocks.find_by(id: params[:source_id])
    @knowledge_block = if source
      @property.knowledge_blocks.new(source.attributes.slice("title", "category", "content", "status"))
    else
      @property.knowledge_blocks.new(status: "active")
    end
  end

  def create
    @knowledge_block = @property.knowledge_blocks.new(knowledge_block_params)

    if @knowledge_block.save
      redirect_to property_path(@property), notice: "Bloque de guía guardado."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @knowledge_block.update(knowledge_block_params)
      redirect_to property_path(@property), notice: "Bloque de guía actualizado."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @knowledge_block.destroy
    redirect_to property_path(@property), notice: "Bloque de guía eliminado."
  end

  private

  def set_property
    @property = current_account.properties.find(params[:property_id])
  end

  def set_knowledge_block
    @knowledge_block = @property.knowledge_blocks.find(params[:id])
  end

  def set_source_knowledge_blocks
    @source_knowledge_blocks = source_knowledge_blocks.order("properties.name ASC", "knowledge_blocks.title ASC")
  end

  def source_knowledge_blocks
    KnowledgeBlock.joins(:property)
      .where(properties: { account_id: current_account.id })
      .where.not(property_id: @property.id)
      .includes(:property)
  end

  def knowledge_block_params
    params.require(:knowledge_block).permit(:title, :category, :content, :status)
  end
end
