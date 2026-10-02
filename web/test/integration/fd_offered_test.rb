require "test_helper"

class FdOfferedTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  def note(body)
    Fd::Note.create!(case_id: @kase.id, body: body, author: "UFF1")
  end

  test "somebody named in a note is offered, not logged" do
    note "spoke to <@U0NAMED01> about it"
    get fd_case_path(@kase, tab: "people")

    assert_empty @kase.participants.where(user_id: "U0NAMED01"),
      "naming somebody must never log them behind your back"
  end

  test "one click adds them as a subject" do
    note "spoke to <@U0NAMED01> about it"
    post fd_case_participants_path(@kase),
      params: { user_ids: ["U0NAMED01"] }

    person = @kase.participants.find_by(user_id: "U0NAMED01")
    assert_equal "subject", person.role
  end
end
