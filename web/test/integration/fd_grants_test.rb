require "test_helper"

class FdGrantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def give(user_id: "U0AFF1", role: "firefighter", **rest)
    post fd_grants_path, params: { user_id: user_id, role: role }.merge(rest)
  end

  test "giving access records the role and who gave it" do
    give

    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")
    assert_equal "firefighter", grant.role
    assert_equal "UME", grant.granted_by
    assert_redirected_to fd_settings_path(person: "U0AFF1")
    assert Fd::AuditEntry.exists?(entity_type: "grant", entity_id: grant.id, verb: "granted")
  end

  test "a grant needs somebody and a role" do
    give(user_id: "")
    assert_match(/search for somebody/, flash[:alert])

    give(role: "boss")
    assert_match(/pick a role/, flash[:alert])

    assert_equal 0, Fd::AccessGrant.where(user_id: "U0AFF1").count
  end

  test "changing a role ends the old grant and starts a new one" do
    give
    give(role: "lead")

    assert_equal "lead", Fd::AccessGrant.role_for("U0AFF1")
    assert_equal 2, Fd::AccessGrant.for_person("U0AFF1").count
    assert_equal 1, Fd::AccessGrant.for_person("U0AFF1").ended.count
  end

  test "taking a grant back leaves the person holding nothing" do
    give
    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")

    delete fd_grant_path(grant)

    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert_equal "UME", grant.reload.revoked_by
    assert Fd::AuditEntry.exists?(entity_type: "grant", entity_id: grant.id, verb: "revoked")
  end

  test "a grant that already ended cannot be taken back twice" do
    give
    grant = Fd::AccessGrant.live.find_by(user_id: "U0AFF1")
    delete fd_grant_path(grant)
    delete fd_grant_path(grant)

    assert_match(/already ended/, flash[:alert])
    assert_equal 1, Fd::AuditEntry.where(entity_type: "grant", verb: "revoked").count
  end

  test "nobody takes their own access back" do
    Fd::AccessGrant.give!("UME", role: "community_manager", by: "UME")
    mine = Fd::AccessGrant.live.find_by(user_id: "UME")

    delete fd_grant_path(mine)

    assert_match(/somebody else has to take yours back/, flash[:alert])
    assert_predicate mine.reload, :live?
  end

  test "a lead cannot hand out access, and the attempt is kept" do
    delete logout_path
    lead = Staff.create!(user_id: "ULEAD", community_manager: false)
    Fd::AccessGrant.give!("ULEAD", role: "lead", by: "UME")
    sign_in_as(lead)

    give

    assert_nil Fd::AccessGrant.role_for("U0AFF1")
    assert_match(/community manager only/, flash[:alert])
    assert Fd::AuditEntry.exists?(verb: "refused")
  end

  test "no form on the settings page sits inside another one" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")

    get fd_settings_path(person: "U0AFF1")

    assert_select "form form", count: 0
  end

  test "the change modal posts the person it is about" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")
    get fd_settings_path(person: "U0AFF1")

    assert_select "form[action=?]", fd_grants_path do
      assert_select "input[name=user_id][value=?]", "U0AFF1"
      assert_select "input[name=role][value=lead]"
    end
  end

  test "the controls are only drawn for somebody who may use them" do
    Fd::AccessGrant.give!("U0AFF1", role: "firefighter", by: "UME")

    get fd_settings_path
    assert_select "label[for=give-access]", text: "Give access"

    get fd_settings_path(person: "U0AFF1")
    assert_select "label[for=change-access]", text: "Change"

    delete logout_path
    lead = Staff.create!(user_id: "ULEAD", community_manager: false)
    Fd::AccessGrant.give!("ULEAD", role: "lead", by: "UME")
    sign_in_as(lead)

    get fd_settings_path
    assert_select "label[for=give-access]", count: 0
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
    get fd_settings_path

    assert_select "#give-access ~ * .seg-radio input[name=role]",
      Fd::Permission::ROLES.size
    assert_select "#give-access ~ * input[name=reason]", 1
  end
end
