require "test_helper"

class FireEngineFlagTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
    Fd::Flag.delete_all
    Current.forget_flags
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def turn_it_off
    Fd::Flag.set!(:fire_engine, false, by: @me.user_id)
  end

  test "with it on, the rail carries the whole section" do
    get root_path

    assert_select "nav[aria-label='Fire Engine'] a", minimum: 2
    assert_select ".rail-label", text: "Fire Engine"
  end

  test "with it off, the section is not in the rail at all" do
    turn_it_off
    get root_path

    assert_select "nav[aria-label='Fire Engine']", count: 0
    assert_select ".rail-label", text: "Fire Engine", count: 0
    assert_select ".rail-label", text: "Main menu", count: 1, message: "analytics is untouched"
  end

  test "with it off, the palette goes with it" do
    turn_it_off
    get root_path

    assert_select "button[data-action='palette#open']", count: 0
    assert_select "#palette", count: 0
  end

  test "with it off, every fire engine page sends you to the overview" do
    turn_it_off
    kase = make_case

    [fd_cases_path, fd_case_path(kase), fd_members_path, fd_search_path].each do |where|
      get where
      assert_redirected_to root_path
      assert_match(/fire engine is turned off/, flash[:alert])
    end
  end

  test "with it off, writing to a case is refused too, not just reading one" do
    turn_it_off
    kase = make_case

    assert_no_difference "Fd::Note.count" do
      post fd_case_notes_path(kase), params: { body: "while the section is off" }
    end
    assert_redirected_to root_path
  end

  test "with it off, settings stays reachable so it can be turned back on" do
    turn_it_off

    get fd_settings_path(tab: "sections")
    assert_response :success

    patch fd_flag_path(key: "fire_engine", on: "1")
    assert Fd::Flag.on?(:fire_engine), "the switch that turns it off must also turn it back on"
  end

  test "with both sections off, the fallback is settings rather than a loop" do
    turn_it_off
    Fd::Flag.set!(:analytics, false, by: @me.user_id)

    get fd_cases_path
    assert_redirected_to fd_settings_path

    get root_path
    assert_redirected_to fd_settings_path
  end

  test "turning it off deletes nothing" do
    kase = make_case
    turn_it_off

    assert Fd::Case.exists?(kase.id)

    Fd::Flag.set!(:fire_engine, true, by: @me.user_id)
    get fd_case_path(kase)
    assert_response :success
  end
end
