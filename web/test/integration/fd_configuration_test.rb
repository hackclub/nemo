require "test_helper"

class FdConfigurationTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "firefighter")
    sign_in_as(@me)
  end

  def word!(**over)
    Fd::AutomodWord.create!({
      word: "badword", match_mode: "word", effect: "flag", added_by: "UMOD"
    }.merge(over))
  end

  def add(**params)
    post fd_automod_words_path, params: { word: "badword" }.merge(params)
  end

  def live = Fd::AutomodWord.active

  test "a firefighter reaches configuration" do
    get fd_configuration_path
    assert_response :success
    assert_match(/Automod/, response.body)
  end

  test "the sidebar carries configuration for whoever may tune it" do
    get fd_configuration_path
    assert_match(%r{href="/fd/configuration"}, response.body)
  end

  test "a community manager reaches it too" do
    drop_roles!("UME")
    hold_role!("UME", "community_manager")
    get fd_configuration_path

    assert_response :success
  end

  test "somebody without the capability is turned away" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    get fd_configuration_path

    assert_response :redirect
  end

  test "a word is put on the list and audited" do
    add(word: "  slur  ", category_key: "harassment_general")
    word = live.sole

    assert_equal "slur", word.word
    assert_equal "word", word.match_mode
    assert_equal "flag", word.effect
    assert_equal "harassment_general", word.category_key
    assert_equal "UME", word.added_by
    assert_equal 1, Fd::AuditEntry.where(entity_type: "automod_word", verb: "added").count
  end

  test "an empty word is refused" do
    add(word: "   ")

    assert_equal 0, live.count
    assert_match(/no word given/, flash[:alert])
  end

  test "the same word is not watched for twice" do
    add
    add

    assert_equal 1, live.count
    assert_match(/already on the list/, flash[:alert])
  end

  test "a regex that does not compile is refused" do
    add(word: "([a-z", match_mode: "regex")

    assert_equal 0, live.count
    assert_match(/does not compile/, flash[:alert])
  end

  test "a regex that compiles is kept" do
    add(word: "ba+dword", match_mode: "regex")

    assert_equal "regex", live.sole.match_mode
  end

  test "an unshipped effect falls back to flag" do
    add(effect: "delete")

    assert_equal "flag", live.sole.effect
  end

  test "an unknown match mode falls back to a whole word" do
    add(match_mode: "sideways")

    assert_equal "word", live.sole.match_mode
  end

  test "a category outside the list is dropped" do
    add(category_key: "not_a_category")

    assert_nil live.sole.category_key
  end

  test "taking a word off keeps it on the record" do
    word = word!
    delete fd_automod_word_path(word)

    assert_equal 0, live.count
    assert_equal "UME", word.reload.retired_by
    assert_not_nil word.retired_at
    assert_equal 1, Fd::AuditEntry.where(entity_type: "automod_word", verb: "removed").count
  end

  test "a word already off the list cannot be taken off again" do
    word = word!
    delete fd_automod_word_path(word)
    delete fd_automod_word_path(word)

    assert_match(/not on the list/, flash[:alert])
  end

  test "a retired word frees the name for a new one" do
    word = word!
    delete fd_automod_word_path(word)
    add(word: "badword")

    assert_equal 1, live.count
    assert_equal 2, Fd::AutomodWord.count
  end

  test "the list is shown masked" do
    word!
    get fd_configuration_path

    assert_select %(.masked), /badword/
  end

  test "matches are shown with the member and the channel" do
    word = word!
    Fd::AutomodMatch.create!(word_id: word.id, word: word.word, effect: "flag",
      user_id: "USUB", channel_id: "C0266FRGV", message_ts: "1700000000.000100",
      body: "the message that matched")
    get fd_configuration_path

    assert_match(/the message that matched/, response.body)
    assert_match(/USUB/, response.body)
  end

  test "the channel on a match opens the message it matched" do
    word = word!
    Fd::AutomodMatch.create!(word_id: word.id, word: word.word, effect: "flag",
      user_id: "USUB", channel_id: "C0266FRGV", message_ts: "1700000000.000100",
      body: "the message that matched",
      permalink: "https://hackclub.slack.com/archives/C0266FRGV/p1700000000000100")
    get fd_configuration_path

    assert_select %(a.handle[href=?]),
      "https://hackclub.slack.com/archives/C0266FRGV/p1700000000000100"
  end

  test "a match with no permalink still links to the channel" do
    word = word!
    Fd::AutomodMatch.create!(word_id: word.id, word: word.word, effect: "flag",
      user_id: "USUB", channel_id: "C0266FRGV", message_ts: "1700000000.000100",
      body: "the message that matched")
    get fd_configuration_path

    assert_select %(a.handle[href*=?]), "C0266FRGV"
  end

  test "somebody without the capability cannot put a word on the list" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    add

    assert_equal 0, live.count
  end
end
