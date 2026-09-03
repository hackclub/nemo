require "test_helper"

class FdAccessTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.eager_load!
    @me = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
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
    Fd::AuditEntry.where(verb: "refused", actor_user_id: @me.user_id)
  end

  DECORATIVE = %w[case.read].freeze

  def self.enforced
    controllers = Rails.application.routes.routes.filter_map { |route|
      route.defaults[:controller].to_s.presence
    }.uniq.select { |name| name.start_with?("fd/") }

    declared = controllers.flat_map { |name| "#{name}_controller".camelize.constantize.declared }
    found = Dir["#{Rails.root}/app/**/*.{rb,erb}"].flat_map { |path|
      File.read(path)
        .scan(/(?:may\?|allow\?|why_not|holds\?|may_community\?)\(\s*(?:[\w.@]+,\s*)?"([\w.]+)"/)
        .flatten
    }
    asked = found + found.filter_map { |key| Community::Access::CAPABILITY[key] }
    (declared + asked).uniq
  end

  test "a permission that guards something has somewhere it is actually checked" do
    unenforced = Authz.keys - self.class.enforced - DECORATIVE

    assert_empty unenforced,
      "#{unenforced.join(', ')} can be moved on the roles tab but nothing reads it, " \
      "so the switch would be inert"
  end

  test "every route that writes names a permission that exists" do
    self.class.fd_writes.each do |name, action|
      keys = controller_for(name).declared
      assert keys.any?, "#{name}##{action} writes without declaring a permission"
      keys.each do |key|
        assert_includes Authz.keys, key, "#{name} names #{key}, which does not exist"
      end
    end
  end

  RULEBOOK = %w[access.grant app.flip].freeze

  test "the rulebook routes are the ones this test covers, and no others" do
    rulebook = self.class.fd_writes.select do |name, _action|
      controller_for(name).declared.intersect?(RULEBOOK)
    end.map(&:first).uniq

    assert_equal %w[fd/role_permissions fd/flags].sort,
      rulebook.sort,
      "a rulebook route appeared or vanished, so this test needs updating"
  end

  test "a firefighter cannot hand out access" do
    post admin_grants_path, params: { user_id: "U0NEW", role: "firefighter", reason: "why not" }

    assert_empty Authz.roles_held("U0NEW")
    assert_redirected_to root_path
  end

  test "a firefighter undoes the work, on a case that is theirs to work" do
    kase = make_case(opened_at: 2.days.ago)
    action = Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UOTHER", performed_by: "UOTHER")

    post fd_case_reversals_path(kase), params: { action_id: action.id,
      reversal_reason: "they appealed" }

    assert_not_nil action.reload.reversed_at
    assert_equal 0, refusals.count
  end

  test "a firefighter is refused on a case assigned to somebody else" do
    kase = make_case(opened_at: 2.days.ago)
    kase.assign!("UOTHER")
    action = Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UOTHER", performed_by: "UOTHER")

    post fd_case_reversals_path(kase), params: { action_id: action.id,
      reversal_reason: "they appealed" }

    assert_nil action.reload.reversed_at
    assert_match(/not to you/, flash[:alert])
    assert_equal "case.reverse", refusals.sole.after["permission"]
    assert_equal %w[firefighter], refusals.sole.after["roles"]
  end

  test "a firefighter still does the work the role is for" do
    kase = make_case(opened_at: 2.days.ago)

    post fd_case_notes_path(kase), params: { body: "asked them to stop" }
    assert_equal 1, kase.notes.count

    post fd_case_actions_path(kase), params: { type_key: "warning", target_user_id: "USUB",
                                               reason: "warned for the same thing twice" }
    assert_equal 1, kase.actions.count

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    assert_not_nil kase.reload.resolved_at

    assert_equal 0, refusals.count
  end

  test "somebody holding no grant writes nothing at all" do
    delete logout_path
    stranger = Account.create!(user_id: "USTRANGER")
    sign_in_as(stranger)
    kase = make_case(opened_at: 2.days.ago)

    post fd_case_notes_path(kase), params: { body: "hello" }

    assert_equal 0, kase.notes.count
    assert_empty Authz.roles_held(stranger.user_id)
  end

  test "a lead holds the undoing, and a manager holds the tool" do
    lead = Account.create!(user_id: "ULEAD")
    hold_role!("ULEAD", "firefighter")

    assert lead.may?("case.reverse")
    assert_not lead.may?("access.grant")

    boss = hold_role!("UBOSS", "community_manager")
    assert boss.may?("access.grant")
  end
end
