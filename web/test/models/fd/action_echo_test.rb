require "test_helper"

class Fd::ActionEchoTest < ActiveSupport::TestCase
  def action(**over)
    Fd::Action.new({ type_key: "warning", target_user_id: "USUB", reason: "kept at it" }.merge(over))
  end

  test "body_for names the action type and the target user" do
    assert_equal "Warning logged on <@USUB>: kept at it", Fd::ActionEcho.body_for(action)
  end

  test "body_for with several actions names each type once" do
    body = Fd::ActionEcho.body_for([action, action(type_key: "dm")])
    assert_equal "Warning, DM logged on <@USUB>: kept at it", body
  end

  test "body_for without target_user_id names a thread" do
    body = Fd::ActionEcho.body_for(action(target_user_id: nil))
    assert_equal "Warning logged on a thread: kept at it", body
  end

  test "body_for with an unlabelled type humanises type_key" do
    body = Fd::ActionEcho.body_for(action(type_key: "some_new_kind"))
    assert_match(/\ASome new kind logged on/, body)
  end

  test "body_for with blank reason omits the reason" do
    body = Fd::ActionEcho.body_for(action(reason: ""))
    assert_equal "Warning logged on <@USUB>", body
  end
end
