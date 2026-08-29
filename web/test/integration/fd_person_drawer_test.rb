require "test_helper"

class FdPersonDrawerTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def get_drawer(user_id)
    get fd_member_path(user_id), headers: { "Turbo-Frame" => "person-drawer" }
  end

  test "requesting a member from the person-drawer frame renders the drawer, not the full page" do
    get_drawer("USUB")

    assert_select "turbo-frame#person-drawer", 1
    assert_select ".pm-head", 1
    assert_select ".ractions", 0, "the full page's header actions do not leak into the drawer"
  end

  test "a plain visit to a member still renders the whole page" do
    get fd_member_path("USUB")

    assert_select "turbo-frame#person-drawer", 1
    assert_select "turbo-frame#person-drawer .drawer-h", 0, "the layout's frame stays empty"
    assert_select ".crumb a[href=?]", fd_members_path
  end

  test "a case note by another author opens their drawer, not a full navigation" do
    kase = make_case(subject: "USUB")
    Fd::Note.create!(case_id: kase.id, body: "spoke to them", author: "UFF1")

    get fd_case_path(kase, tab: "notes")

    assert_select ".note-by a.lnk[data-turbo-frame=person-drawer]", text: "@UFF1"
  end

  test "a member with nothing on record still renders the drawer" do
    get_drawer("UNOBODY")

    assert_select ".person-modal"
    assert_select ".note-none", text: "Never named in a case."
    assert_select ".fstat b", text: "0", count: 3
  end

  test "the drawer shows what was done to them, and their notes, nothing else" do
    kase = make_case(subject: "UAAA")
    Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "UAAA",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 2.days.ago,
      source_app: "fire_engine")
    Fd::Note.create!(subject_user_id: "UAAA", body: "watch for repeats", author: "UFF2")

    get_drawer("UAAA")

    assert_select ".pm-label", text: "Cases they appear in"
    assert_select ".fstat span", text: "actions"
    assert_select ".fstat span", text: "in force"
    assert_select ".pm-foot .btn", { text: "Open the full record" },
      "the summary points at the record rather than repeating it"
  end
end
