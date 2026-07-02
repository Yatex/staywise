require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "local datetime renders in app timezone instead of utc" do
    utc_time = Time.utc(2026, 7, 1, 12, 35)

    assert_equal "America/Montevideo", Time.zone.tzinfo.name
    I18n.with_locale(:es) do
      assert_equal "01/07/2026 09:35", local_datetime(utc_time)
    end
  end
end
