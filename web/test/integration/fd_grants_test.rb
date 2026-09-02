require "test_helper"

class FdGrantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def give(user_id: "U0AFF1", role: "firefighter", **rest)
    post admin_grants_path, params: { user_id: user_id, fd_role: role }.merge(rest)
  end

  test "giving access records the role and who gave it" do
    give

    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")
    assert_equal "firefighter", grant.role
    assert_equal "UME", grant.granted_by
    assert_redirected_to admin_person_path("U0AFF1")
    assert Fd::AuditEntry.exists?(entity_type: "grant", entity_id: grant.id, verb: "granted")
  end

  test "a grant needs somebody" do
    give(user_id: "")
    assert_match(/search for somebody/, flash[:alert])

    give(user_id: "not-an-id")
    assert_match(/is not a Slack user id/, flash[:alert])

    assert_equal 0, Fd::AccessGrant.where(user_id: "U0AFF1").count
  end

  test "changing a role ends the old grant and starts a new one" do
    give
    give(role: "lead")

    assert_equal "lead", Fd::AccessGrant.role_for("U0AFF1")
    assert_equal 2, Fd::AccessGrant.for_person("U0AFF1").count
    assert_equal 1, Fd::AccessGrant.for_person("U0AFF1").ended.count
  end

  test "taking everything back leaves the person holding nothing, and says so in the trail" do
    give
    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")

    delete admin_grant_path("U0AFF1")

    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert_equal "UME", grant.reload.revoked_by
    assert Fd::AuditEntry.exists?(entity_type: "grant", entity_id: grant.id, verb: "revoked")
  end

  test "unpicking the fire department rung takes that grant back" do
    give
    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")

    post admin_grants_path, params: { user_id: "U0AFF1" }

    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert Fd::AuditEntry.exists?(entity_type: "grant", entity_id: grant.id, verb: "revoked")
  end

  test "the last manager cannot lock everybody out by taking their own back" do
    delete admin_grant_path("UME")

    assert_match(/somebody else has to take yours back/, flash[:alert])
    assert_predicate Staff.find("UME"), :manager?
  end

  test "a lead cannot reach the grant endpoints at all" do
    delete logout_path
    lead = Staff.create!(user_id: "ULEAD", community_manager: false)
    Fd::AccessGrant.give!("ULEAD", role: "lead", by: "UME")
    sign_in_as(lead)

    give

    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert_redirected_to root_path
  end

  test "making somebody a manager is written to the trail, and takes their fd grant" do
    give
    post admin_grants_path, params: { user_id: "U0AFF1", fd_role: "community_manager" }

    assert_predicate Staff.find("U0AFF1"), :manager?
    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert Fd::AuditEntry.where(verb: "granted")
      .any? { |row| row.after&.dig("role") == "community_manager" }
  end

  test "no form on the settings page sits inside another one" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")

    get admin_person_path("U0AFF1")

    assert_select "form form", count: 0
  end

  test "the edit modal posts the person it is about, prefilled with what they hold" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")
    get admin_person_path("U0AFF1")

    assert_select "form[action=?]", admin_grants_path do
      assert_select "input[name=user_id][value=?]", "U0AFF1"
      assert_select "input[name=fd_role][value=firefighter][checked]"
    end
  end

  test "the controls are only drawn for somebody who may use them" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")

    get admin_people_path
    assert_select "label[for=give-access]", text: "Give access"

    get admin_person_path("U0AFF1")
    assert_select "label[for=give-access]", text: "Edit access"

    delete logout_path
    lead = Staff.create!(user_id: "ULEAD", community_manager: false)
    Fd::AccessGrant.give!("ULEAD", role: "lead", by: "UME")
    sign_in_as(lead)

    get admin_people_path
    assert_redirected_to root_path, "the admin section is managers only"
  end

  test "a reason is kept on the grant when one is given" do
    give(reason: "covering the weekend")

    assert_equal "covering the weekend", Fd::AccessGrant.live.find_by(user_id: "U0AFF1").reason
  end

  test "a grant without a reason is still allowed, since the field is optional" do
    give

    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")
    assert_nil grant.reason
    assert_equal "firefighter", grant.role
  end

  test "a blank reason is stored as nothing rather than an empty string" do
    give(reason: "   ")

    assert_nil Fd::AccessGrant.live.find_by(user_id: "U0AFF1").reason
  end

  test "the give modal offers the role as a segmented row and an optional reason" do
    get admin_people_path

    assert_select "#give-access ~ * .seg-radio input[name=fd_role]",
      Fd::Permission::ROLES.size,
      "the manager rung is offered, clicking a picked one again clears it"
    Community::Permission.families.each do |family|
      assert_select "#give-access ~ * .seg-radio input[name=#{family}_role]",
        Community::Permission.roles(family).size
    end
    assert_select "#give-access ~ * input[name=reason]", 1
  end
end
