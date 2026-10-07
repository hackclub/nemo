require "test_helper"

class Fd::MemberFinderTest < ActiveSupport::TestCase
  include SeedsPipelineTables

  setup do
    @staff = hold_role!("UFINDER1", "community_manager")
  end

  def named!(user_id, display_name, handle: nil, real_name: nil, email: nil, deleted: false, bot: false)
    as_pipeline("INSERT INTO fd.member (user_id, handle, display_name, is_deleted, is_bot) " \
                "VALUES (?, ?, ?, ?, ?) ON CONFLICT (user_id) DO UPDATE SET handle = EXCLUDED.handle, " \
                "display_name = EXCLUDED.display_name, is_deleted = EXCLUDED.is_deleted, " \
                "is_bot = EXCLUDED.is_bot",
      user_id, handle || user_id.downcase, display_name, deleted, bot)
    seeded!("fd.member", "user_id", user_id)
    if real_name || email
      as_pipeline("INSERT INTO fd.member_identity (user_id, real_name, email) VALUES (?, ?, ?) " \
                  "ON CONFLICT (user_id) DO UPDATE SET real_name = EXCLUDED.real_name, " \
                  "email = EXCLUDED.email", user_id, real_name, email)
      seeded!("fd.member_identity", "user_id", user_id)
    end
    user_id
  end

  def found(term, actor: @staff, limit: 20)
    Fd::MemberFinder.new(term, actor: actor).find(limit: limit)
  end

  test "an id, however it was pasted, finds that one member and nobody else" do
    named!("U0ZQ7Y4KD1", "Zorblax Quintrell")
    named!("U0ZQ7Y4KD2", "Zorblax Quintrell Jr")

    ["U0ZQ7Y4KD1", "u0zq7y4kd1", "@U0ZQ7Y4KD1", "<@U0ZQ7Y4KD1>", "<@U0ZQ7Y4KD1|zorblax>",
     "https://hackclub.slack.com/team/U0ZQ7Y4KD1"].each do |pasted|
      assert_equal ["U0ZQ7Y4KD1"], found(pasted).ids, pasted
      assert_equal 1, found(pasted).total, pasted
    end
  end

  test "an id nobody holds finds nobody rather than guessing by name" do
    named!("U0ZQ7Y4KD1", "U0NOBODY99 fan club")

    assert_empty found("U0NOBODY99").ids
  end

  test "an id is found even when it only shows up in a case" do
    make_case(subject: "U0CASEONLY", opened_at: 2.days.ago)

    assert_equal ["U0CASEONLY"], found("U0CASEONLY").ids
  end

  test "the words can come in any order" do
    named!("U0ZQ7Y4KD1", "Zorblax Quintrell")

    assert_includes found("quintrell zorblax").ids, "U0ZQ7Y4KD1"
    assert_includes found("zorb quint").ids, "U0ZQ7Y4KD1"
  end

  test "the exact name comes first" do
    named!("U0ZQ7Y4KD1", "Mirelle Okontawi")
    named!("U0ZQ7Y4KD2", "Mirelle Okonta")

    assert_equal "U0ZQ7Y4KD2", found("mirelle okonta").ids.first
  end

  test "a name that starts with the word ranks above one that only contains it" do
    named!("U0ZQ7Y4KD1", "Aquintrella Vorn")
    named!("U0ZQ7Y4KD2", "Zorblax Quintrella")

    ids = found("quintrella").ids
    assert_operator ids.index("U0ZQ7Y4KD2"), :<, ids.index("U0ZQ7Y4KD1")
  end

  test "a typo still finds them" do
    named!("U0ZQ7Y4KD1", "Zorblax Quintrell")

    assert_includes found("zorblax qiuntrell").ids, "U0ZQ7Y4KD1"
  end

  test "bots are not found by name, but a pasted bot id still resolves" do
    named!("U0ZQ7Y4KB1", "Zorblax Quintrell Bot", bot: true)

    assert_not_includes found("zorblax quintrell bot").ids, "U0ZQ7Y4KB1"
    assert_equal ["U0ZQ7Y4KB1"], found("U0ZQ7Y4KB1").ids
  end

  test "a deleted account is found by name only when conduct work touched it" do
    named!("U0ZQ7Y4KX1", "Zorblax Gonewald", deleted: true)
    assert_not_includes found("gonewald").ids, "U0ZQ7Y4KX1"

    make_case(subject: "U0ZQ7Y4KX1", opened_at: 2.days.ago)
    assert_includes found("gonewald").ids, "U0ZQ7Y4KX1"
  end

  test "somebody with a conduct history outranks a namesake without one" do
    named!("U0ZQ7Y4KD1", "Zorblax Twinning")
    named!("U0ZQ7Y4KD2", "Zorblax Twinning")
    make_case(subject: "U0ZQ7Y4KD2", opened_at: 2.days.ago)

    assert_equal "U0ZQ7Y4KD2", found("zorblax twinning").ids.first
  end

  test "a match in the name people see ranks above one only in a hidden real name" do
    named!("U0ZQ7Y4KD1", "Quillon Vex")
    named!("U0ZQ7Y4KD2", "spacecat", real_name: "Quillon Brightwater")
    make_case(subject: "U0ZQ7Y4KD2", opened_at: 2.days.ago)

    ids = found("quillon").ids
    assert_operator ids.index("U0ZQ7Y4KD1"), :<, ids.index("U0ZQ7Y4KD2")
  end

  test "an exact name people see beats the same name hidden in a real name" do
    named!("U0ZQ7Y4KD1", "lynnzo")
    named!("U0ZQ7Y4KD2", "ghost of lynnzora", real_name: "lynnzo")
    make_case(subject: "U0ZQ7Y4KD2", opened_at: 2.days.ago)

    assert_equal "U0ZQ7Y4KD1", found("lynnzo").ids.first
  end

  test "real names and emails are only searched for staff who may read identities" do
    named!("U0ZQ7Y4KD1", "tamz", real_name: "Tamsin Okafor-Reyes", email: "tamsin.or@throwaway.example")

    assert_includes found("okafor").ids, "U0ZQ7Y4KD1"
    assert_not_includes found("okafor", actor: nil).ids, "U0ZQ7Y4KD1"
  end

  test "an exact email finds that one member" do
    named!("U0ZQ7Y4KD1", "tamz", email: "tamsin.or@throwaway.example")
    named!("U0ZQ7Y4KD2", "tamsin or", email: "tamsin.or2@throwaway.example")

    assert_equal ["U0ZQ7Y4KD1"], found("Tamsin.OR@throwaway.example").ids
  end

  test "the total counts every match while the ids stop at the limit" do
    3.times { |n| named!("U0ZQ7Y4KV#{n}", "Vexmorran #{n}") }

    result = found("vexmorran", limit: 2)
    assert_equal 2, result.ids.size
    assert_equal 3, result.total
  end

  test "punctuation and pattern characters are searched as text" do
    assert_nothing_raised { found("50%_off:x it's") }
    assert_nothing_raised { found(":limit :whole ?") }
  end

  test "an empty box asks nothing" do
    assert_equal [[], 0], found("  ").to_a
    assert_equal [[], 0], found("@").to_a
  end

  def picked(term, **opts)
    Fd::MemberFinder.new(term, actor: @staff).pick(limit: Fd::Member::LIMIT, **opts)
  end

  test "the picker takes the words in any order and puts an exact name or handle first" do
    named!("U0ZQ7Y4KD1", "Mirelle Okontawi")
    named!("U0ZQ7Y4KD2", "Mirelle Okonta")
    named!("U0ZQ7Y4KD3", "spacecat", handle: "okontawi")

    assert_equal "U0ZQ7Y4KD2", picked("mirelle okonta").first
    assert_equal "U0ZQ7Y4KD3", picked("okontawi").first
    assert_includes picked("okontawi mirelle"), "U0ZQ7Y4KD1"
  end

  test "the picker needs three letters, but a pasted id resolves straight away" do
    named!("U0ZQ7Y4KD1", "Zo Quintrell")

    assert_empty picked("zo")
    assert_empty picked("@zo")
    assert_equal ["U0ZQ7Y4KD1"], picked("<@U0ZQ7Y4KD1>")
    assert_empty picked("U0NOBODY99")
  end

  test "the picker leaves out deleted accounts and bots, even ones conduct work touched" do
    named!("U0ZQ7Y4KX1", "Zorblax Gonewald", deleted: true)
    named!("U0ZQ7Y4KB1", "Zorblax Gonewald Bot", bot: true)
    make_case(subject: "U0ZQ7Y4KX1", opened_at: 2.days.ago)

    assert_empty picked("gonewald")
    assert_equal ["U0ZQ7Y4KB1"], picked("gonewald", bots: true)
    assert_equal ["U0ZQ7Y4KX1"], picked("U0ZQ7Y4KX1")
  end

  test "the picker for everyone lists deleted accounts and bots after live members" do
    named!("U0ZQ7Y4KD1", "Zorblax Quintrell")
    named!("U0ZQ7Y4KX1", "Zorblax Quintrell", deleted: true)
    named!("U0ZQ7Y4KB1", "Zorblax Quintrell", bot: true)

    assert_equal %w[U0ZQ7Y4KD1 U0ZQ7Y4KB1 U0ZQ7Y4KX1], picked("zorblax quintrell", everyone: true)
    assert_equal %w[U0ZQ7Y4KD1], picked("zorblax quintrell")
  end

  test "on a case the people on it come first among equal matches, never above a closer one" do
    named!("U0ZQ7Y4KD1", "Zorblax Twinning")
    named!("U0ZQ7Y4KD2", "Zorblax Twinning")
    named!("U0ZQ7Y4KD3", "Zorblax Twinningham")
    kase = make_case(subject: "U0ZQ7Y4KD2", opened_at: 2.days.ago)
    kase.add_subject!("U0ZQ7Y4KD3")

    assert_equal %w[U0ZQ7Y4KD2 U0ZQ7Y4KD1 U0ZQ7Y4KD3], picked("zorblax twinning", case_id: kase.id)
    assert_equal %w[U0ZQ7Y4KD1 U0ZQ7Y4KD2 U0ZQ7Y4KD3], picked("zorblax twinning")
  end

  test "on a case, being on it sorts under the match and over how much they talk" do
    sql = Fd::MemberFinder.new("zorblax", actor: @staff).pick_sql(8, case_id: 7)
    order = sql[sql.rindex("ORDER BY")..]

    assert_operator order.index("k.place"), :<, order.index("party.case_id = 7")
    assert_operator order.index("party.case_id = 7"), :<, order.index("w.messages_posted DESC")
  end
end
