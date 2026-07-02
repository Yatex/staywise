class AiDecisionLog < ApplicationRecord
  belongs_to :account, optional: true
  belongs_to :property, optional: true
  belongs_to :guest, optional: true
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true
end
