require "test_helper"

class FdDecisionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def write(**attrs)
    Fd::Decision.create!({
      title: "Spam accounts",
      statement: "A first-post account posting an invite link is banned on sight.",
      proposed_by: "UFF1"
    }.merge(attrs))
  end

  def settled(**attrs)
    decision = write(**attrs)
    decision.settle!(by: "ULEAD")
    decision
  end

  def titles
    css_select("td .two-line b").map(&:text).map(&:strip)
  end

  test "a signed out visitor cannot read the log" do
    delete logout_path
    get fd_decisions_path
    assert_redirected_to login_path
  end

  test "the log lists what is in force, what is proposed and what is retired" do
    rule = settled(title: "Pile-ons")
    write(title: "Appeals")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decisions_path

    assert_response :success
    assert_equal ["Pile-ons", "Appeals", "Warnings by DM"], titles
    assert_select ".card-title", text: "In force"
    assert_select ".card-title", text: "Proposed"
    assert_select ".card-title", text: "Retired"
  end

  test "a band nobody has filled is left out of the page" do
    settled(title: "Pile-ons")
    get fd_decisions_path

    assert_select ".card-title", text: "In force"
    assert_select ".card-title", text: "Proposed", count: 0
    assert_select ".card-title", text: "Retired", count: 0
  end

  test "picking a state shows that state alone, even when it is empty" do
    settled(title: "Pile-ons")
    get fd_decisions_path(view: "proposed")

    assert_select ".card-title", text: "Proposed"
    assert_select ".card-title", text: "In force", count: 0
    assert_select ".card-note", text: "Nothing in this state."
  end

  test "a state nobody offered falls back to the whole log" do
    settled(title: "Pile-ons")
    get fd_decisions_path(view: "vanished")

    assert_select ".card-title", text: "In force"
    assert_select ".view[aria-current]", text: /All/
  end

  test "the counts match what each state holds" do
    rule = settled(title: "Pile-ons")
    write(title: "Appeals")
    settled(title: "Night shift")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decisions_path

    assert_select ".views .view", text: /All\s*4/
    assert_select ".views .view", text: /In force\s*2/
    assert_select ".views .view", text: /Proposed\s*1/
    assert_select ".views .view", text: /Retired\s*1/
  end

  test "a row says what the decision is, what it says, and who settled it" do
    decision = settled(title: "Pile-ons",
      statement: "One lock and a note to the loudest three, not five cases.")
    decision.threads.create!(channel_id: "C1", thread_ts: "1.1", added_by: "UFF1")
    decision.threads.create!(channel_id: "C1", thread_ts: "2.2", added_by: "UFF1")

    get fd_decisions_path

    assert_select ".col-said", text: "One lock and a note to the loudest three, not five cases."
    assert_select "td", text: "2 threads"
    assert_select ".idline", text: /settled .* by/
    assert_select ".chip.chip-good", text: "in force"
  end

  test "a decision nobody linked a thread to says so plainly" do
    settled(title: "Night shift")
    get fd_decisions_path

    assert_select "td", text: "n/a"
  end

  test "a retired decision names what replaced it" do
    rule = settled(title: "Spam accounts")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decisions_path(view: "retired")

    assert_select ".idline", text: /replaced by Spam accounts/
    assert_select ".chip.chip-off", text: "retired"
  end

  test "an empty log says so rather than showing an empty table" do
    get fd_decisions_path

    assert_select ".card-note", text: "Nothing written down yet."
    assert_select ".data-table", count: 0
  end

  test "the rail carries the log next to cases and members" do
    get fd_decisions_path
    assert_select ".rail-item[aria-current='page']", text: /Decisions/
  end
end
