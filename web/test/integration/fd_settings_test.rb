require "test_helper"

class FdSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def give(user_id, role: "firefighter", **attrs)
    Fd::AccessGrant.give!(user_id, role: role, by: "UME", **attrs)
  end

  test "a signed out visitor sees nothing" do
    delete logout_path
    get fd_settings_path
    assert_redirected_to login_path
  end

  test "the roster lists who holds what, and who gave it" do
    give("UFF1", reason: "night shift")
    give("ULEAD", role: "lead")

    get fd_settings_path

    assert_response :success
    assert_select ".head-title", text: "Settings"
    assert_select ".chip.chip-off", text: "firefighter"
    assert_select ".chip.chip-warn", text: "lead"
    assert_select "td", text: /UFF1/
  end

  test "the subtitle counts the roster by role" do
    Fd::AccessGrant.delete_all
    give("UFF1")
    give("UFF2")
    give("ULEAD", role: "lead")

    get fd_settings_path
    assert_select ".head-meta", text: /3 people · 1 lead · 2 firefighters/
  end

  test "an empty roster says so" do
    Fd::AccessGrant.delete_all
    get fd_settings_path

    assert_select ".card-note", text: "Nobody holds a grant yet."
  end

  test "a grant nobody has used in a month is called out" do
    give("UQUIET", at: 3.months.ago)
    give("UBUSY")
    Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine")

    get fd_settings_path

    assert_select ".strip b", text: /UQUIET has held a firefighter grant/
    assert_select ".strip", count: 1
  end

  test "a fresh grant is not called dormant" do
    give("UNEW")
    get fd_settings_path

    assert_select ".strip", count: 0
  end

  test "the roster says when each person last acted" do
    give("UBUSY")
    Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine", occurred_at: 2.days.ago)

    get fd_settings_path

    assert_select "td.col-num", text: "1"
    assert_select "td", text: /ago/
  end

  test "the history tab keeps the grants that ended" do
    grant = give("UGONE", reason: "left FD")
    grant.take_back!(by: "UME")
    give("UHERE", reason: "still here")

    get fd_settings_path(tab: "history")

    assert_select ".said-cell", text: "left FD"
    assert_select ".chip.chip-off", text: "ended"
    assert_select ".chip.chip-good", text: "live"
  end

  test "a tab nobody offered falls back to the roster" do
    give("UFF1")
    get fd_settings_path(tab: "vibes")

    assert_select ".view[aria-current]", text: /Access/
  end

  test "the rail carries settings" do
    get fd_settings_path
    assert_select ".rail-item[aria-current='page']", text: /Settings/
  end
end
