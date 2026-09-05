require "test_helper"

class FdMessagesTest < ActionDispatch::IntegrationTest
  setup do
    @me = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
    sign_in_as(@me)
  end
end
