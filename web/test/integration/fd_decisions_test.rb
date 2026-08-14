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

  test "a signed out visitor cannot read the log" do
    delete logout_path
    get fd_decisions_path
    assert_redirected_to login_path
  end

  test "the log renders with every state on it" do
    rule = settled(title: "Pile-ons")
    write(title: "Appeals")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    get fd_decisions_path
    assert_response :success

    get fd_decisions_path(view: "retired")
    assert_response :success
  end

  test "an empty log renders" do
    get fd_decisions_path
    assert_response :success
  end

  test "the page renders for a proposal, a rule and a retired one" do
    proposal = write(title: "Appeals")
    rule = settled(title: "Pile-ons", category_key: "harassment_general",
      reasons: ["five cases for one thread is bookkeeping"])
    rule.threads.create!(channel_id: "C0266FRGV", thread_ts: "1.1",
      added_by: "UFF1", why: "where it was decided")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    [proposal, rule, dead].each do |decision|
      get fd_decision_path(decision)
      assert_response :success
    end
  end

  test "a thread can be picked out of the pane by id" do
    decision = settled(title: "Spam accounts")
    decision.threads.create!(channel_id: "C0FIREHOUSE", thread_ts: "1.1", added_by: "UME")
    second = decision.threads.create!(channel_id: "C0LOUNGE", thread_ts: "2.2",
      added_by: "UME", kind: "reference")

    get fd_decision_path(decision, thread: second.id)
    assert_response :success
  end

  test "a decision nobody wrote cannot be opened" do
    get fd_decision_path(999_999)
    assert_response :not_found
  end

  test "writing one lands it as proposed, under whoever wrote it" do
    post fd_decisions_path, params: { title: "Screenshots as evidence",
      statement: "A screenshot alone is never enough to act, ask for the permalink.",
      category_key: "spam" }

    decision = Fd::Decision.sole
    assert_predicate decision, :proposed?
    assert_equal "UME", decision.proposed_by
    assert_equal "spam", decision.category_key
    assert_redirected_to fd_decision_path(decision)
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: decision.id,
      verb: "proposed")
  end

  test "a decision with no name or no sentence is refused" do
    post fd_decisions_path, params: { title: "", statement: "something" }
    post fd_decisions_path, params: { title: "Appeals", statement: "  " }

    assert_equal 0, Fd::Decision.count
  end

  test "a category nobody offered is dropped rather than stored" do
    post fd_decisions_path, params: { title: "Appeals", statement: "read by somebody else",
      category_key: "vibes" }

    assert_nil Fd::Decision.sole.category_key
  end

  test "two live decisions cannot share a name" do
    settled(title: "Spam accounts")
    post fd_decisions_path, params: { title: "spam accounts", statement: "again" }

    assert_equal 1, Fd::Decision.count
  end

  test "a signed out visitor cannot write one" do
    delete logout_path
    post fd_decisions_path, params: { title: "Appeals", statement: "read by somebody else" }

    assert_equal 0, Fd::Decision.count
  end

  test "a proposal can be reworded, and the reasons are one per line" do
    decision = write(title: "Appeals")
    patch fd_decision_path(decision), params: { title: "Appeals",
      statement: "An appeal is read by somebody who was not on the case.",
      reasons: "the first reader has already made up their mind\n\n  it costs one message  " }

    decision.reload
    assert_equal "An appeal is read by somebody who was not on the case.", decision.statement
    assert_equal ["the first reader has already made up their mind", "it costs one message"],
      decision.reasons
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: decision.id,
      verb: "amended")
  end

  test "settling makes it the rule, and says who agreed" do
    decision = write(title: "Appeals")
    post fd_decision_settlement_path(decision)

    decision.reload
    assert_predicate decision, :settled?
    assert_equal "UME", decision.settled_by
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: decision.id,
      verb: "settled")
  end

  test "settling twice is refused, so the first agreement stands" do
    decision = settled(title: "Pile-ons")
    post fd_decision_settlement_path(decision)

    assert_equal "ULEAD", decision.reload.settled_by
  end

  test "a settled decision is amended, and stays settled" do
    decision = settled(title: "Pile-ons")
    patch fd_decision_path(decision), params: { title: "Pile-ons",
      statement: "One lock and a note to the loudest three, unless it is a raid." }

    decision.reload
    assert_predicate decision, :settled?
    assert_equal "ULEAD", decision.settled_by
    assert_equal "One lock and a note to the loudest three, unless it is a raid.",
      decision.statement
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: decision.id,
      verb: "amended")
  end

  test "a retired decision is neither edited nor amended" do
    rule = settled(title: "Spam accounts")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    patch fd_decision_path(dead), params: { title: "Warnings by DM", statement: "no" }

    assert_not_equal "no", dead.reload.statement
  end

  test "superseding writes the replacement and retires the old one in one move" do
    old = settled(title: "Warnings by DM", reasons: ["it was quieter"])
    post fd_decision_supersession_path(old), params: { title: "Spam accounts",
      statement: "Banned on sight for a first-post invite link.",
      category_key: "spam", reasons: "warning a throwaway does nothing" }

    fresh = Fd::Decision.in_force.sole
    old.reload

    assert_equal "Spam accounts", fresh.title
    assert_equal "UME", fresh.settled_by
    assert_equal ["warning a throwaway does nothing"], fresh.reasons
    assert_predicate old, :superseded?
    assert_equal fresh.id, old.replaced_by_id
    assert_equal "UME", old.retired_by
    assert_redirected_to fd_decision_path(fresh)
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: old.id,
      verb: "superseded")
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: fresh.id,
      verb: "settled")
  end

  test "a replacement with no sentence is refused, and nothing is retired" do
    old = settled(title: "Warnings by DM")
    post fd_decision_supersession_path(old), params: { title: "Spam accounts", statement: "" }

    assert_predicate old.reload, :settled?
    assert_equal 1, Fd::Decision.count
  end

  test "a replacement cannot reuse the name of a live decision" do
    settled(title: "Spam accounts")
    old = settled(title: "Warnings by DM")
    post fd_decision_supersession_path(old), params: { title: "spam accounts",
      statement: "something" }

    assert_predicate old.reload, :settled?
  end

  test "a proposal cannot be superseded, it was never the rule" do
    old = write(title: "Appeals")
    post fd_decision_supersession_path(old), params: { title: "Appeals, again",
      statement: "something" }

    assert_equal 1, Fd::Decision.count
  end

  test "a rule can be retired without anything replacing it" do
    decision = settled(title: "Night shift")
    post fd_decision_retirement_path(decision)

    decision.reload
    assert_predicate decision, :superseded?
    assert_nil decision.replaced_by_id
    assert_equal "UME", decision.retired_by
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: decision.id,
      verb: "superseded")
  end

  test "a proposal is dropped, not retired" do
    decision = write(title: "Appeals")
    post fd_decision_retirement_path(decision)

    assert_predicate decision.reload, :proposed?
  end

  test "retiring twice is refused" do
    decision = settled(title: "Night shift")
    post fd_decision_retirement_path(decision)
    post fd_decision_retirement_path(decision)

    assert_equal 1, Fd::AuditEntry.where(entity_id: decision.id, verb: "superseded").count
  end

  test "a signed out visitor cannot settle or supersede" do
    decision = write(title: "Appeals")
    delete logout_path

    post fd_decision_settlement_path(decision)
    assert_predicate decision.reload, :proposed?

    post fd_decision_supersession_path(decision), params: { title: "x", statement: "y" }
    assert_equal 1, Fd::Decision.count
  end

  test "whoever proposed it can drop it, and nobody else can" do
    mine = write(title: "Appeals", proposed_by: "UME")
    theirs = write(title: "Night shift", proposed_by: "UFF1")

    delete fd_decision_path(theirs)
    assert Fd::Decision.exists?(theirs.id)

    delete fd_decision_path(mine)
    assert_not Fd::Decision.exists?(mine.id)
    assert_redirected_to fd_decisions_path
    assert Fd::AuditEntry.exists?(entity_type: "decision", entity_id: mine.id, verb: "dropped")
  end

  test "a settled decision cannot be dropped" do
    decision = settled(title: "Pile-ons", proposed_by: "UME")
    delete fd_decision_path(decision)

    assert Fd::Decision.exists?(decision.id)
  end

  test "several links land as several threads in one go" do
    decision = settled(title: "Spam accounts")
    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456\n" \
             "https://hackclub.slack.com/archives/C0155HFRGV/p1754079880123456\n",
      why: "where it was decided"
    }

    assert_equal 2, decision.threads.count
    assert_equal ["C0155HFRGV", "C0266FRGV"], decision.threads.map(&:channel_id).sort
    assert_equal ["where it was decided"], decision.threads.map(&:why).uniq
    assert_equal "UME", decision.threads.first.added_by
    assert_equal 2, Fd::AuditEntry.where(entity_type: "decision_thread", verb: "attached",
      entity_id: decision.id).count
  end

  test "a thread is internal discussion unless it says otherwise" do
    decision = settled(title: "Spam accounts")
    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456"
    }
    assert_predicate decision.threads.sole, :internal?

    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0LOUNGE/p1754079880123456",
      kind: "reference", why: "the wave that started it"
    }
    assert_predicate decision.threads.reference.sole, :reference?
  end

  test "a kind nobody offered falls back to internal" do
    decision = settled(title: "Spam accounts")
    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456",
      kind: "evidence"
    }

    assert_predicate decision.threads.sole, :internal?
  end

  test "a line that is not a Slack thread link is dropped, and the rest still land" do
    decision = settled(title: "Spam accounts")
    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456\n" \
             "https://example.com/nope\nnot a link at all"
    }

    assert_equal 1, decision.threads.count
  end

  test "the same thread twice in one paste is linked once" do
    decision = settled(title: "Spam accounts")
    link = "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456"
    post fd_decision_threads_path(decision), params: { links: "#{link}\n#{link}" }

    assert_equal 1, decision.threads.count
  end

  test "a thread already linked keeps the reason it was linked with" do
    decision = settled(title: "Spam accounts")
    link = "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456"
    post fd_decision_threads_path(decision), params: { links: link, why: "first reason" }
    post fd_decision_threads_path(decision), params: { links: link, why: "second reason" }

    assert_equal 1, decision.threads.count
    assert_equal "first reason", decision.threads.sole.why
  end

  test "an empty paste links nothing" do
    decision = settled(title: "Spam accounts")
    post fd_decision_threads_path(decision), params: { links: "   " }

    assert_equal 0, decision.threads.count
  end

  test "unlinking a thread leaves the trail behind" do
    decision = settled(title: "Spam accounts")
    thread = decision.threads.create!(channel_id: "C1", thread_ts: "1.1", added_by: "UME",
      why: "the wave")

    delete fd_decision_thread_path(decision, thread)

    assert_equal 0, decision.threads.count
    entry = Fd::AuditEntry.where(entity_type: "decision_thread", verb: "detached").sole
    assert_equal decision.id, entry.entity_id
    assert_equal "the wave", entry.before["why"]
  end

  test "a thread on another decision cannot be unlinked from this one" do
    mine = settled(title: "Spam accounts")
    theirs = settled(title: "Pile-ons")
    thread = theirs.threads.create!(channel_id: "C1", thread_ts: "1.1", added_by: "UME")

    delete fd_decision_thread_path(mine, thread)

    assert_equal 1, theirs.threads.count
  end

  test "a signed out visitor cannot link a thread" do
    decision = settled(title: "Spam accounts")
    delete logout_path
    post fd_decision_threads_path(decision), params: {
      links: "https://hackclub.slack.com/archives/C0266FRGV/p1754079240123456"
    }

    assert_equal 0, decision.threads.count
  end
end
