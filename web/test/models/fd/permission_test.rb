require "test_helper"

class Fd::PermissionTest < ActiveSupport::TestCase
  def manager
    @manager ||= Staff.create!(user_id: "UBOSS", community_manager: true)
  end

  def firefighter
    @firefighter ||= holding("UFF", "firefighter")
  end

  def lead
    @lead ||= holding("ULEAD", "lead")
  end

  def holding(user_id, role)
    Staff.create!(user_id: user_id, community_manager: false)
    Fd::AccessGrant.give!(user_id, role: role, by: "UBOSS")
    Staff.find(user_id)
  end

  test "every permission names a role somebody can hold" do
    Fd::Permission.keys.each do |key|
      roles = Fd::Permission.roles(key)
      assert roles.any?, "#{key} belongs to nobody"
      assert_empty roles - Fd::Permission::ROLES, "#{key} names a role that does not exist"
    end
  end

  test "every permission says what it lets you do, and where it lives" do
    Fd::Permission.keys.each do |key|
      assert Fd::Permission.label(key).present?, "#{key} has no label"
      assert Fd::Permission.area(key).present?, "#{key} belongs to no area"
    end
  end

  test "every scope rule is one the code knows" do
    Fd::Permission.keys.each do |key|
      scope = Fd::Permission.scope(key)
      next if scope.nil?

      assert_includes Fd::Permission::SCOPES, scope, "#{key} names an unknown scope"
    end
  end

  test "every audited event names a verb the audit accepts" do
    Fd::Permission.keys.each do |key|
      Fd::Permission.events(key).each do |event|
        entity, verb = event.split("/")
        assert entity.present?, "#{key} has a malformed event"
        assert_includes Fd::Audit::VERBS, verb, "#{key} claims a verb nobody writes"
      end
    end
  end

  test "the three roles stack, the work then the rules then the tool itself" do
    assert_equal 16, Fd::Permission.held_by("firefighter").size
    assert_equal 18, Fd::Permission.held_by("lead").size
    assert_equal 21, Fd::Permission.held_by("community_manager").size
    assert_equal Fd::Permission.keys.size, Fd::Permission.held_by("community_manager").size

    assert_equal %w[decision.settle decision.retire access.read access.grant app.flip].sort,
      Fd::Permission.lead_only.sort
    assert_equal %w[access.read access.grant app.flip].sort, Fd::Permission.manager_only.sort
  end

  test "a firefighter does the conduct work, including undoing it" do
    assert firefighter.may?("case.act")
    assert firefighter.may?("case.reverse")
    assert firefighter.may?("case.reopen")
    assert firefighter.may?("identity.read")
    assert firefighter.may?("decision.settle"), "the lead ladder is gone"
  end

  test "a lead settles the rules but does not hand out access" do
    assert lead.may?("decision.settle")
    assert lead.may?("decision.retire")
    assert_not lead.may?("access.grant")
  end

  test "a community manager holds the tool itself" do
    assert manager.may?("access.grant")
    assert manager.may?("decision.settle")
    assert_predicate manager, :manager?
    assert_predicate manager, :lead?
  end

  test "somebody with no staff row holds nothing" do
    assert_nil Fd::Access.role(nil)
    assert_not Fd::Access.allow?(nil, "case.read")
  end

  test "a case write is refused on somebody else's case, whatever the role" do
    boss = lead
    kase = make_case(opened_at: 2.days.ago)
    kase.assign!("UOTHER")

    assert boss.may?("case.act"), "the role holds it"
    assert_not boss.may?("case.act", kase), "but the case is not theirs"
    assert_not boss.may?("case.reverse", kase), "reversing is scoped to the assignment too"
  end

  test "a free case is anybody's to work" do
    kase = make_case(opened_at: 2.days.ago)

    assert firefighter.may?("case.act", kase)
  end

  test "a note is its author's to delete" do
    kase = make_case(opened_at: 2.days.ago)
    theirs = Fd::Note.create!(case_id: kase.id, body: "not mine", author: "UOTHER")
    mine = Fd::Note.create!(case_id: kase.id, body: "mine", author: "UFF")

    assert firefighter.may?("case.note", mine)
    assert_not firefighter.may?("case.note", theirs)
  end

  test "handing out access is the one permission nobody can move" do
    assert Fd::Permission.locked?("access.grant")
    assert_not Fd::Permission.locked?("case.reverse")
    assert_not Fd::Permission.locked?("decision.settle")
  end

  test "a refusal says which rule stopped it" do
    assert_equal "settle a proposal, putting it in force is lead only",
      Fd::Permission.refusal("decision.settle")
    assert_equal "give or take back access is community manager only",
      Fd::Permission.refusal("access.grant")
    assert_equal "that is not yours", Fd::Permission.refusal("case.act")
    assert_equal "you cannot make that change", Fd::Permission.refusal("nonsense")
  end

  test "asking about a permission nobody defined is an error, not a quiet no" do
    assert_raises(Fd::Permission::Unknown) { Fd::Permission.roles("case.vanish") }
  end
end
