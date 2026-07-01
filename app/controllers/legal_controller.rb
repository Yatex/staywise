class LegalController < ApplicationController
  skip_before_action :require_authentication

  def terms
  end

  def privacy
  end
end
