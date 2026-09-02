require "test_helper"

class AnalyticsFlagTest < ActionDispatch::IntegrationTest
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
    Fd::Flag.set!(:analytics, false, by: @me.user_id)
  end

  test "with it off, every analytics page sends you to the queue" do
    turn_it_off

    [root_path, channels_path, engine_path].each do |where|
      get where
      assert_redirected_to fd_cases_path
      assert_match(/community analytics is turned off/, flash[:alert])
    end
  end

  test "with it off, the pipeline's buttons are refused too, not just its page" do
    turn_it_off

    post engine_sync_path
    assert_redirected_to fd_cases_path
  end

  test "with it on, the pages still load" do
    get channels_path
    assert_response :success

    get root_path
    assert_response :success
  end

  test "a channel named in a case reads the same either way, but stops linking" do
    real = Analytics::DimChannel.where(archived: false).first.channel_id
    kase = make_case
    Fd::Note.create!(case_id: kase.id, body: "it was in <##{real}>", author: @me.user_id)

    get fd_case_path(kase)
    assert_select "a.mention[href=?]", channel_path(real)

    turn_it_off
    get fd_case_path(kase)
    assert_select "a.mention[href=?]", channel_path(real), count: 0
    assert_select "span.mention"
  end

  test "a channel nobody can open is named but never linked" do
    kase = make_case
    Fd::Note.create!(case_id: kase.id, body: "it was in <#C0GONE>", author: @me.user_id)

    get fd_case_path(kase)

    assert_select "a.mention[href=?]", channel_path("C0GONE"), count: 0
    assert_select "span.mention", text: /C0GONE/
  end

  test "turning it off does not take the channel names with it" do
    turn_it_off
    kase = make_case
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0LOUNGE", thread_ts: "1.1",
      is_primary: true, added_by: @me.user_id)

    get fd_case_path(kase, tab: "evidence")
    assert_response :success
  end
end
