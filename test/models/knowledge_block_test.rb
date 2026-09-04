require "test_helper"

class KnowledgeBlockTest < ActiveSupport::TestCase
  setup do
    account = Account.create!(name: "YouTube URL security")
    @property = account.properties.create!(name: "Secure property")
  end

  test "accepts only exact official YouTube HTTPS hosts" do
    %w[
      https://youtube.com/watch?v=abc123
      https://www.youtube.com/watch?v=abc123
      https://m.youtube.com/watch?v=abc123
      https://youtu.be/abc123
    ].each do |url|
      assert build_block(url).valid?, url
    end
  end

  test "rejects unsafe schemes credentials ports and deceptive hosts" do
    [
      "http://youtube.com/watch?v=abc123",
      "javascript:alert(1)",
      "data:text/html,unsafe",
      "file:///etc/passwd",
      "https://youtube.com.attacker.example/watch?v=abc123",
      "https://attacker-youtube.com/watch?v=abc123",
      "https://youtube.com@attacker.example/watch?v=abc123",
      "https://youtube.com:8443/watch?v=abc123",
      "not a URL"
    ].each do |url|
      block = build_block(url)
      assert_not block.valid?, url
      assert block.errors[:youtube_url].any?, url
    end
  end

  private

  def build_block(url)
    @property.knowledge_blocks.new(
      title: "Manual",
      category: "appliances",
      content: "Instrucciones",
      status: "active",
      youtube_url: url
    )
  end
end
