require "test_helper"

class Fd::ChatListenerTest < ActiveSupport::TestCase
  test "a payload that is a case number is read as one" do
    assert_equal 2633, Fd::ChatListener.case_id_from("2633")
  end

  test "anything else is ignored rather than raising in the listener thread" do
    assert_nil Fd::ChatListener.case_id_from("case 2633")
    assert_nil Fd::ChatListener.case_id_from("")
    assert_nil Fd::ChatListener.case_id_from(nil)
  end

  test "the listener stays out of the test suite" do
    assert_not Fd::ChatListener.wanted?
  end

  test "a console or a rake task is not a server, so it does not listen" do
    assert_not Fd::ChatListener.serving?
  end
end
