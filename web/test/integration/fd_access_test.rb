require "test_helper"

class FdAccessTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.eager_load!
    @me = Staff.create!(user_id: "UFF1", community_manager: false)
    Fd::AccessGrant.give!("UFF1", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
  end

  def self.fd_writes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller].to_s
      next unless controller.start_with?("fd/")

      verbs = route.verb.to_s.gsub(/[$^]/, "").split("|")
      next if (verbs - %w[GET HEAD]).empty?

      [controller, route.defaults[:action].to_s]
    end.uniq
  end

  def controller_for(name)
    "#{name}_controller".camelize.constantize
  end

  def refusals
    Fd::AuditEntry.where(verb: "refused")
  end

  test "every route that writes names a permission that exists" do
    self.class.fd_writes.each do |name, action|
      keys = controller_for(name).declared
      assert keys.any?, "#{name}##{action} writes without declaring a permission"
      keys.each do |key|
        assert_includes Fd::Permission.keys, key, "#{name} names #{key}, which does not exist"
      end
    end
  end

  test "the lead-only routes are the ones this test covers, and no others" do
    lead_only = self.class.fd_writes.select do |name, _action|
      controller_for(name).declared.intersect?(Fd::Permission.lead_only)
    end.map(&:first).uniq

    assert_equal %w[fd/resolutions fd/reversals fd/settlements fd/supersessions
                    fd/retirements].sort, lead_only.sort,
      "a lead-only route appeared or vanished, so this test needs updating"
  end

  test "a firefighter cannot reverse an action, and the attempt is kept" do
    kase = make_case(opened_at: 2.days.ago)
    action = Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UOTHER", performed_by: "UOTHER")

    post fd_case_reversals_path(kase), params: { action_id: action.id,
      reversal_reason: "they appealed" }

    assert_nil action.reload.reversed_at
    assert_match(/lead only/, flash[:alert])
    assert_equal 1, refusals.where(verb: "refused").count
    assert_equal "case.reverse", refusals.sole.after["permission"]
    assert_equal "firefighter", refusals.sole.after["role"]
  end

  test "a firefighter cannot reopen a resolved case" do
    kase = make_case(opened_at: 3.days.ago)
    kase.update!(resolved_at: 1.day.ago, resolution: "no_action")

    delete fd_case_resolution_path(kase)

    assert_not_nil kase.reload.resolved_at
    assert_equal "case.reopen", refusals.sole.after["permission"]
  end

  test "a firefighter cannot settle, supersede or retire a decision" do
    proposal = Fd::Decision.create!(title: "Appeals", statement: "read by somebody else",
      proposed_by: "UFF1")
    rule = Fd::Decision.create!(title: "Pile-ons", statement: "one lock and a note",
      proposed_by: "UFF1")
    rule.settle!(by: "UBOSS")

    post fd_decision_settlement_path(proposal)
    assert_predicate proposal.reload, :proposed?

    post fd_decision_supersession_path(rule), params: { title: "Pile-ons, again",
      statement: "something else" }
    assert_predicate rule.reload, :settled?

    post fd_decision_retirement_path(rule)
    assert_predicate rule.reload, :settled?

    assert_equal %w[decision.retire decision.retire decision.settle],
      refusals.map { |row| row.after["permission"] }.sort
  end

  test "a firefighter still does the work the role is for" do
    kase = make_case(opened_at: 2.days.ago)

    post fd_case_notes_path(kase), params: { body: "asked them to stop" }
    assert_equal 1, kase.notes.count

    post fd_case_actions_path(kase), params: { type_key: "warning", target_user_id: "USUB" }
    assert_equal 1, kase.actions.count

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    assert_not_nil kase.reload.resolved_at

    assert_equal 0, refusals.count
  end

  test "somebody holding no grant writes nothing at all" do
    delete logout_path
    stranger = Staff.create!(user_id: "USTRANGER", community_manager: false)
    sign_in_as(stranger)
    kase = make_case(opened_at: 2.days.ago)

    post fd_case_notes_path(kase), params: { body: "hello" }

    assert_equal 0, kase.notes.count
    assert_nil stranger.role
  end

  test "a lead holds the undoing, and a manager holds the tool" do
    lead = Staff.create!(user_id: "ULEAD", community_manager: false)
    Fd::AccessGrant.give!("ULEAD", role: "lead", by: "UBOSS")

    assert lead.may?("case.reverse")
    assert lead.may?("decision.settle")
    assert_not lead.may?("access.grant")

    boss = Staff.create!(user_id: "UBOSS", community_manager: true)
    assert boss.may?("access.grant")
  end
end
