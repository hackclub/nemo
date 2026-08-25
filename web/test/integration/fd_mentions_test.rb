require "test_helper"

class FdMentionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
    @named = Fd::Member.live.order(:user_id).first
    sign_in_as(@me)
  end

  test "a typed handle is stored the way slack writes it" do
    post fd_case_notes_path(@kase), params: { about: "case", body: "spoke to @#{@named.user_id}" }

    assert_equal "spoke to <@#{@named.user_id}>", @kase.notes.sole.body
  end

  test "a mention renders as the member's name, not the raw id" do
    Fd::Note.create!(case_id: @kase.id, body: "spoke to <@#{@named.user_id}> in DM",
      author: "UFF1")
    get fd_case_path(@kase)

    assert_select "a.mention", text: "@#{@named.name}"
    assert_no_match(/&lt;@#{@named.user_id}&gt;/, response.body)
  end

  test "a mention links to the member page" do
    Fd::Note.create!(case_id: @kase.id, body: "<@#{@named.user_id}> was there", author: "UFF1")
    get fd_case_path(@kase)

    assert_select "a.mention[href=?]", fd_member_path(@named.user_id)
    assert_select "a.mention[title=?]", @named.user_id
  end

  test "a mention of somebody we have no name for falls back to the handle" do
    Fd::Note.create!(case_id: @kase.id, body: "<@U0STRANGER1> turned up", author: "UFF1")
    get fd_case_path(@kase)

    assert_select "a.mention", text: "@U0STRANGER1"
    assert_select "a.mention[href=?]", fd_member_path("U0STRANGER1")
  end

  test "markup in a note is still escaped around the mentions" do
    Fd::Note.create!(case_id: @kase.id, author: "UFF1",
      body: "<script>alert(1)</script> said <@#{@named.user_id}>")
    get fd_case_path(@kase)

    assert_no_match(%r{<script>alert\(1\)</script>}, response.body)
    assert_match(/&lt;script&gt;/, response.body)
    assert_select "a.mention", text: "@#{@named.name}"
  end

  test "a standing note written from the member page mentions too" do
    post fd_member_notes_path("UPRIOR"), params: { body: "watch them near @#{@named.user_id}" }

    assert_equal "watch them near <@#{@named.user_id}>", Fd::Note.for_subject("UPRIOR").sole.body

    get fd_member_path("UPRIOR")
    assert_select "a.mention[href=?]", fd_member_path(@named.user_id)
  end

  test "the first note on a new case mentions too" do
    post fd_cases_path, params: { subject_user_ids: ["USUBJ01"],
                                  body: "reported by @#{@named.user_id}" }

    opened = Fd::Case.order(:id).last
    assert_equal "reported by <@#{@named.user_id}>", opened.notes.sole.body
  end

  test "every note field offers the picker on typing an at sign" do
    get fd_case_path(@kase)
    assert_select ".mention-field[data-mention-url-value=?]", fd_member_search_path

    get fd_member_path("UPRIOR", show: "notes")
    assert_select ".mention-field[data-mention-url-value=?]", fd_member_search_path

    get fd_cases_path
    assert_select ".mention-field[data-mention-url-value=?]", fd_member_search_path
  end
end
