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

  def bands
    css_select(".band-label").map { |band| band.text.split("·").first.strip }
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
    assert_equal ["In force", "Proposed", "Retired"], bands
  end

  test "a band nobody has filled is left out of the page" do
    settled(title: "Pile-ons")
    get fd_decisions_path

    assert_equal ["In force"], bands
  end

  test "picking a state shows that state alone, even when it is empty" do
    settled(title: "Pile-ons")
    get fd_decisions_path(view: "proposed")

    assert_equal ["Proposed"], bands
    assert_select ".card-note", text: "Nothing in this state."
  end

  test "a band says how many it holds and what the state means" do
    settled(title: "Pile-ons")
    write(title: "Appeals")

    get fd_decisions_path

    assert_select ".band-label", text: /In force · 1 · what FD does today/
    assert_select ".band-label", text: /Proposed · 1 · waiting on a lead/
  end

  test "a state nobody offered falls back to the whole log" do
    settled(title: "Pile-ons")
    get fd_decisions_path(view: "vanished")

    assert_equal ["In force"], bands
    assert_select ".view[aria-current]", text: /All/
  end

  test "the counts match what each state holds" do
    rule = settled(title: "Pile-ons")
    write(title: "Appeals")
    settled(title: "Night shift")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decisions_path

    assert_select ".head-meta", text: /2 in force · 1 proposed · 1 retired/
    assert_select ".band-label", text: /In force · 2/
    assert_select ".band-label", text: /Proposed · 1/
    assert_select ".band-label", text: /Retired · 1/
  end

  test "a row says what the decision is, what it says, who settled it and how many threads" do
    decision = settled(title: "Pile-ons",
      statement: "One lock and a note to the loudest three, not five cases.")
    decision.threads.create!(channel_id: "C1", thread_ts: "1.1", added_by: "UFF1")
    decision.threads.create!(channel_id: "C1", thread_ts: "2.2", added_by: "UFF1")

    get fd_decisions_path

    assert_select ".said-cell", text: "One lock and a note to the loudest three, not five cases."
    assert_select ".idline", text: /settled .* by .* · 2 threads/
    assert_select ".chip.chip-good", text: "in force"
  end

  test "a decision nobody linked a thread to says so plainly" do
    settled(title: "Night shift")
    get fd_decisions_path

    assert_select ".idline", text: /no threads/
  end

  test "how many cases followed a decision is not known yet" do
    settled(title: "Night shift")
    get fd_decisions_path

    assert_select "td.col-num", text: "n/a"
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

  test "a row opens the decision it names" do
    decision = settled(title: "Pile-ons")
    get fd_decisions_path

    assert_select "a[href=?]", fd_decision_path(decision)
  end

  test "the page reads the sentence, then why, then where it was argued" do
    decision = settled(title: "Pile-ons", category_key: "harassment_general",
      statement: "One lock and a note to the loudest three, not five cases.",
      reasons: ["five cases for one thread is bookkeeping, not conduct work",
                "the quiet ones stop reading when everybody gets a case"])
    decision.threads.create!(channel_id: "C0266FRGV", thread_ts: "1.1",
      added_by: "UFF1", why: "where it was decided")

    get fd_decision_path(decision)

    assert_response :success
    assert_select ".head-title", text: "Pile-ons"
    assert_select ".dec-said", text: "One lock and a note to the loudest three, not five cases."
    assert_select ".fact-line", count: 2
    assert_select ".band-label", text: /Where it was argued · 1 thread/
    assert_select ".thr-where", text: "C0266FRGV"
    assert_select ".thr-why", text: "where it was decided"
    assert_select ".head-meta", text: /systematic harassment, general/
  end

  test "a decision with nothing behind it yet says so twice over" do
    get fd_decision_path(settled(title: "Night shift"))

    assert_select ".card-note", text: "No reasons written down."
    assert_select ".card-note", text: "No thread linked."
    assert_select ".band-label", text: /Where it was argued · none linked/
  end

  test "the history says who proposed it, who settled it and what replaced it" do
    rule = settled(title: "Spam accounts")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decision_path(dead)

    assert_select ".thr-gone", text: /proposed .* settled .* retired .* replaced by/
    assert_select "a[href=?]", fd_decision_path(rule)
  end

  test "the decision that replaced another says which one it replaced" do
    rule = settled(title: "Spam accounts")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decision_path(rule)

    assert_select ".fact-line", text: /Replaced .*Warnings by DM.*retired/m
  end

  test "the pager walks the log and stops at both ends" do
    newest = settled(title: "Night shift")
    oldest = settled(title: "Pile-ons")
    oldest.update!(settled_at: 3.months.ago)

    get fd_decision_path(newest)
    assert_select ".btn.is-off", text: "Previous"
    assert_select "a.btn[href=?]", fd_decision_path(oldest), text: "Next"

    get fd_decision_path(oldest)
    assert_select ".btn.is-off", text: "Next"
    assert_select "a.btn[href=?]", fd_decision_path(newest), text: "Previous"
  end

  test "a decision nobody wrote cannot be opened" do
    get fd_decision_path(999_999)
    assert_response :not_found
  end
end
