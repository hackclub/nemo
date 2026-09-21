require "test_helper"

class Fd::MemberTest < ActiveSupport::TestCase
  test "the picker puts a member whose display name is the term before anyone who merely contains it" do
    named = Fd::Member.live.where.not(display_name: [nil, ""]).where("length(display_name) >= 4")
      .where("display_name !~ '[%_]'").order(:user_id).first
    skip "the corpus has no member with a display name" if named.nil?

    first = Fd::Member.search(named.display_name).first
    assert_equal named.display_name.downcase, first.display_name.to_s.downcase
  end

  test "an exact handle outranks a name that only starts with the term" do
    named = Fd::Member.live.where.not(handle: [nil, ""]).where("length(handle) >= 4")
      .where("handle !~ '[%_]'").order(:user_id).first
    skip "the corpus has no member with a handle" if named.nil?

    assert_equal named.user_id, Fd::Member.search(named.handle).first.user_id
  end

  test "two people share a name, and the one already on the case is meant" do
    stranger, party = two_of("Sahil Namesake")
    kase = make_case(subject: party.user_id)

    assert_equal party.user_id, Fd::Member.search("Sahil Namesake", case_id: kase.id).first.user_id
    assert_equal stranger.user_id, Fd::Member.search("Sahil Namesake").first.user_id,
      "off the case they are only told apart by id, so the order is the plain one"
  end

  test "two people share a name, and the one who talks is meant" do
    quiet, loud = two_of("Busy Namesake")
    spoke!(loud.user_id, 50_000)

    assert_equal loud.user_id, Fd::Member.search("Busy Namesake").first.user_id
    assert_equal quiet.user_id, Fd::Member.search("Busy Namesake").second.user_id
  end

  test "an exact name beats a busier person who merely contains the term" do
    exact = make_member("UEXACT1", "Quiet Zephyr")
    within = make_member("UWITHIN1", "Quiet Zephyrine")
    spoke!(within.user_id, 900_000)

    assert_equal exact.user_id, Fd::Member.search("Quiet Zephyr").first.user_id
  end

  test "the busiest match survives a term too common to list, whatever the alphabet says" do
    crowd = (1..(Fd::Member::SHORTLIST + 10)).map do |n|
      { user_id: format("UCROWD%03d", n), display_name: format("Wraith aaa%03d", n),
        is_bot: false, is_deleted: false }
    end
    Fd::Member.insert_all!(crowd)
    loud = make_member("ULOUDWR", "Wraith zzz")
    spoke!(loud.user_id, 400_000)

    assert_equal loud.user_id, Fd::Member.search("Wraith").first.user_id,
      "the shortlist is cut by how much they talk, not by name"
  end

  test "being on the case does not lift somebody over a closer match" do
    exact = make_member("UEXACT2", "Loud Cypher")
    within = make_member("UWITHIN2", "Loud Cypherton")
    kase = make_case(subject: within.user_id)

    assert_equal exact.user_id, Fd::Member.search("Loud Cypher", case_id: kase.id).first.user_id
  end

  private

  def make_member(user_id, display_name)
    Fd::Member.create!(user_id: user_id, display_name: display_name,
      is_bot: false, is_deleted: false)
  end

  def two_of(display_name)
    tag = display_name.delete("^A-Za-z").upcase[0, 5]
    [make_member("UA#{tag}", display_name), make_member("UB#{tag}", display_name)]
  end

  def spoke!(user_id, messages)
    Analytics::MemberWindow.insert_all!([{ user_id: user_id, messages_posted: messages,
      source: Analytics::MemberWindow::LIFETIME_SOURCE }])
  end
end
