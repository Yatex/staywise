require "test_helper"

class AdminAccessTest < ActionDispatch::IntegrationTest
  setup do
    @admin_account = Account.create!(name: "Admin Account")
    @admin_account.subscriptions.create!(plan: "business", status: "active")
    @admin = @admin_account.users.create!(
      name: "Admin User",
      email: "admin-test@staywise.test",
      role: "admin",
      password: "password123",
      password_confirmation: "password123"
    )

    @owner_account = Account.create!(name: "Owner Account")
    @owner_account.subscriptions.create!(plan: "starter", status: "trialing")
    @owner = @owner_account.users.create!(
      name: "Owner User",
      email: "owner-test@staywise.test",
      role: "owner",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "normal users cannot access admin sections" do
    sign_in_as(@owner)

    get admin_users_path

    assert_redirected_to dashboard_path
  end

  test "admins can access users and stats sections" do
    sign_in_as(@admin)

    get admin_users_path
    assert_response :success

    get admin_stats_path
    assert_response :success
  end

  test "admin can extend an account subscription" do
    sign_in_as(@admin)

    post extend_subscription_admin_user_path(@owner), params: {
      plan: "pro",
      end_date: 45.days.from_now.to_date
    }

    assert_redirected_to admin_users_path
    subscription = @owner_account.active_subscription.reload
    assert_equal "pro", subscription.plan
    assert_equal "active", subscription.status
    assert subscription.current_period_end > 40.days.from_now
  end

  test "admin can update another user's role" do
    sign_in_as(@admin)

    patch update_role_admin_user_path(@owner), params: { role: "member" }

    assert_redirected_to admin_users_path
    assert_equal "member", @owner.reload.role
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
