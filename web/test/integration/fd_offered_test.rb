require "test_helper"

class FdOfferedTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
    sign_in_as(@me)
  end

  def note(body)
    Fd::Note.create!(case_id: @kase.id, body: body, author: "UFF1")
  end

  test "somebody named in a note is offered, not logged" do
    note "spoke to <@U0NAMED01> about it"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered a.mention", text: "@U0NAMED01"
    assert_select ".offered form[action=?]", fd_case_participants_path(@kase)
    assert_empty @kase.participants.where(user_id: "U0NAMED01"),
      "naming somebody must never log them behind your back"
  end

  test "one click logs them as involved" do
    note "spoke to <@U0NAMED01> about it"
    post fd_case_participants_path(@kase),
      params: { user_ids: ["U0NAMED01"], role: "involved" }

    person = @kase.participants.find_by(user_id: "U0NAMED01")
    assert_equal "involved", person.role
    assert_nil person.detail, "the reason is optional, so one click is enough"
  end

  test "once logged they stop being offered" do
    note "spoke to <@U0NAMED01> about it"
    @kase.participants.create!(user_id: "U0NAMED01", role: "involved")
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered", 0
  end

  test "the subject is never offered, they are already the point of the case" do
    note "this is about <@USUB> obviously"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered", 0
  end

  test "a firefighter named in a note is not offered as involved" do
    Staff.create!(user_id: "UFF9", community_manager: true)
    note "asked <@UFF9> to read the thread"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered", 0, "logging a firefighter as involved would be a lie"
  end

  test "whoever opened the case is not offered either" do
    note "as <@UFF1> said when opening it"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered", 0
  end

  test "somebody named in a report is offered too" do
    Fd::CaseReport.create!(case_id: @kase.id, body: "<@U0NAMED02> was there as well",
      is_anonymous: true, source_app: "shroud", received_at: 1.day.ago)
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered a.mention", text: "@U0NAMED02"
  end

  test "several names are each offered separately" do
    note "both <@U0NAMED01> and <@U0NAMED02> were in it"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered-one", 2
    assert_select ".offered a.mention", text: "@U0NAMED01"
    assert_select ".offered a.mention", text: "@U0NAMED02"
  end

  test "the same name twice is offered once" do
    note "<@U0NAMED01> then <@U0NAMED01> again"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered-one", 1
  end

  test "a standing note on the subject can offer somebody too" do
    Fd::Note.create!(subject_user_id: "USUB", body: "watch them near <@U0NAMED03>",
      author: "UFF1")
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered a.mention", text: "@U0NAMED03"
  end

  test "nothing named means no strip at all" do
    note "nobody named here"
    get fd_case_path(@kase, tab: "people")

    assert_select ".offered", 0
  end
end
