require "test_helper"

class FdMentionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
    @named = Fd::Member.live.order(:user_id).first
    sign_in_as(@me)
  end

  test "a typed handle is stored the way slack writes it" do
    post fd_case_notes_path(@kase), params: { about: "case", body: "spoke to @#{@named.user_id}" }

    assert_equal "spoke to <@#{@named.user_id}>", @kase.notes.sole.body
  end

  test "a standing note written from the member page mentions too" do
    post fd_member_notes_path("UPRIOR"), params: { body: "watch them near @#{@named.user_id}" }

    assert_equal "watch them near <@#{@named.user_id}>", Fd::Note.for_subject("UPRIOR").sole.body

    get fd_member_path("UPRIOR")
  end

  test "the first note on a new case mentions too" do
    post fd_cases_path, params: { subject_user_ids: ["USUBJ01"],
                                  body: "reported by @#{@named.user_id}" }

    opened = Fd::Case.order(:id).last
    assert_equal "reported by <@#{@named.user_id}>", opened.notes.sole.body
  end
end
