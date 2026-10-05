require "test_helper"

class Fd::ActionEchoTest < ActiveSupport::TestCase
  def action(**over)
    Fd::Action.new({ type_key: "warning", target_user_id: "USUB", reason: "kept at it" }.merge(over))
  end

  test "names the action and the person it is against" do
    assert_equal "Warning logged on <@USUB>: kept at it", Fd::ActionEcho.body_for(action)
  end

  test "an action against a thread names it as such" do
    body = Fd::ActionEcho.body_for(action(target_user_id: nil))
    assert_equal "Warning logged on a thread: kept at it", body
  end

  test "a type with no label falls back to its key, humanised" do
    body = Fd::ActionEcho.body_for(action(type_key: "some_new_kind"))
    assert_match(/\ASome new kind logged on/, body)
  end

  test "no reason recorded leaves it off rather than printing nothing" do
    body = Fd::ActionEcho.body_for(action(reason: ""))
    assert_equal "Warning logged on <@USUB>", body
  end

  test "a resolution note becomes its own line" do
    body = Fd::ActionEcho.body_for(action(resolution_note: "talked it through"))
    assert_equal "Warning logged on <@USUB>: kept at it\nHow it was solved: talked it through",
      body
  end

  test "no resolution note recorded adds no second line" do
    body = Fd::ActionEcho.body_for(action(resolution_note: ""))
    assert_not_includes body, "How it was solved"
  end
end
