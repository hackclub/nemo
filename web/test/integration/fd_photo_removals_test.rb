require "test_helper"

class FdPhotoRemovalsTest < ActionDispatch::IntegrationTest
  MEMBER = "UPHOTO0001".freeze
  IMAGE = "\x89PNG-original".b.freeze

  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def removals = Fd::PhotoRemoval.where(member_id: MEMBER)

  def without_member_guard
    revoke_roles!("UME")
    grant_role!("UME", "firefighter")
    override_capability!("firefighter", "member.guard", false)
  end

  def remove_photo(**over)
    post fd_member_photo_removals_path(MEMBER), params: { reason: "nsfw pfp" }.merge(over)
  end

  def deactivate(**over)
    post fd_member_guards_path(MEMBER),
      params: { kind: Fd::MemberGuard::DEACTIVATION, reason: "nsfw pfp" }.merge(over)
  end

  def finished_removal(**over)
    Fd::PhotoRemoval.create!({ member_id: MEMBER, asked_by: "UME", state: "done",
                               finished_at: Time.current, reason: "nsfw pfp" }.merge(over))
  end

  def store_evidence(removal, image: IMAGE, content_type: "image/png")
    Fd::PhotoRemovalEvidence.create!(removal_id: removal.id, image: image, content_type: content_type,
      sha256: Digest::SHA256.hexdigest(image))
  end

  test "create queues a removal with the reason and no guard" do
    remove_photo

    removal = removals.sole

    assert_equal ["asked", "UME", "nsfw pfp", nil], [removal.state, removal.asked_by, removal.reason, removal.guard_id]
    assert_redirected_to fd_member_path(MEMBER)
    assert_match(/Pfp removal queued/, flash[:notice])
  end

  test "create audits the queued removal against the member" do
    remove_photo

    entry = Fd::AuditEntry.where(entity_type: "member_photo", verb: "queued").sole

    assert_equal [removals.sole.id, MEMBER, "UME"], [entry.entity_id, entry.subject_user_id, entry.actor_user_id]
  end

  test "create without a reason queues a removal with no reason" do
    remove_photo(reason: "  ")

    assert_nil removals.sole.reason
  end

  test "create while a removal is waiting queues no second removal" do
    remove_photo
    remove_photo

    assert_equal 1, removals.count
    assert_match(/already queued/, flash[:alert])
  end

  test "create after the previous removal finished queues another" do
    finished_removal
    remove_photo

    assert_equal 2, removals.count
  end

  test "create for something that is not a member id queues nothing" do
    post fd_member_photo_removals_path("nope"), params: { reason: "x" }

    assert_equal 0, Fd::PhotoRemoval.count
    assert_match(/not a member id/, flash[:alert])
  end

  test "create without member.guard queues nothing" do
    without_member_guard
    remove_photo

    assert_equal 0, removals.count
  end

  test "deactivation with remove_photo queues a removal on the guard" do
    deactivate(remove_photo: "1")

    removal = removals.sole

    assert_equal [Fd::MemberGuard.where(subject_id: MEMBER).sole.id, "asked", "nsfw pfp"],
      [removal.guard_id, removal.state, removal.reason]
    assert_match(/Pfp removal queued/, flash[:notice])
    assert_equal 1, Fd::AuditEntry.where(entity_type: "member_photo", verb: "queued").count
  end

  test "deactivation without remove_photo queues no removal" do
    deactivate

    assert Fd::MemberGuard.where(subject_id: MEMBER).exists?
    assert_equal 0, removals.count
    assert_no_match(/Pfp removal/, flash[:notice])
  end

  test "scheduled deactivation with remove_photo queues a removal on the scheduled guard" do
    deactivate(remove_photo: "1", starts_on: 2.days.from_now.to_date.iso8601)

    assert_equal Fd::MemberGuard.where(subject_id: MEMBER).sole.id, removals.sole.guard_id
  end

  test "shush with remove_photo queues no removal" do
    post fd_member_guards_path(MEMBER), params: { kind: "shush", reason: "loud", remove_photo: "1" }

    assert_equal 0, removals.count
  end

  test "deactivation with an existing waiting removal queues no second removal" do
    Fd::PhotoRemoval.create!(member_id: MEMBER, asked_by: "UME")
    deactivate(remove_photo: "1")

    assert_equal 1, removals.count
    assert Fd::MemberGuard.where(subject_id: MEMBER).exists?
    assert_match(/Pfp removal already queued/, flash[:notice])
  end

  test "member page renders the remove_photo checkbox and the removal modal" do
    get fd_member_path(MEMBER)

    assert_select %(input[name="remove_photo"][type="checkbox"])
    assert_select %(form[action="#{fd_member_photo_removals_path(MEMBER)}"] textarea[name="reason"])
    assert_select %(form[action="#{fd_member_photo_removals_path(MEMBER)}"] label), text: /Reason \(optional\)/
    assert_select "button[data-modal-open=?]", "member-photo-removal"
  end

  test "member page without member.guard renders no removal modal" do
    without_member_guard
    get fd_member_path(MEMBER)

    assert_select %(form[action="#{fd_member_photo_removals_path(MEMBER)}"]), count: 0
  end

  test "history lists a finished removal with who asked and the reason" do
    removal = finished_removal
    store_evidence(removal)
    get fd_member_path(MEMBER, tab: "history")

    assert_response :success
    assert_select ".member-timeline b a[href=?]", fd_member_photo_removal_path(MEMBER, removal), text: "Pfp removed"
    assert_match(/nsfw pfp/, response.body)
  end

  test "history lists a removal without evidence as plain text" do
    finished_removal
    get fd_member_path(MEMBER, tab: "history")

    assert_select ".member-timeline b", text: "Pfp removed"
    assert_select ".member-timeline b a", text: "Pfp removed", count: 0
  end

  test "history lists a failed removal with its error" do
    finished_removal(state: "failed", error: "profile lookup failed")
    get fd_member_path(MEMBER, tab: "history")

    assert_select ".member-timeline b", text: "Pfp removal failed"
    assert_match(/profile lookup failed/, response.body)
  end

  test "history leaves out a removal that is still waiting" do
    Fd::PhotoRemoval.create!(member_id: MEMBER, asked_by: "UME")
    get fd_member_path(MEMBER, tab: "history")

    assert_no_match(/Pfp removed/, response.body)
  end

  test "show serves the saved image inline with a locked-down policy" do
    removal = finished_removal
    store_evidence(removal)
    get fd_member_photo_removal_path(MEMBER, removal)

    assert_response :success
    assert_equal IMAGE, response.body.b
    assert_equal "image/png", response.media_type
    assert_match(/\Ainline/, response.headers["Content-Disposition"])
    assert_equal "default-src 'none'; sandbox", response.headers["Content-Security-Policy"]
  end

  test "show serves an unrecognised content type as an attachment" do
    removal = finished_removal
    store_evidence(removal, content_type: "application/octet-stream")
    get fd_member_photo_removal_path(MEMBER, removal)

    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
  end

  test "show without saved evidence is not found" do
    removal = finished_removal
    get fd_member_photo_removal_path(MEMBER, removal)

    assert_response :not_found
  end

  test "show under another member does not find the removal" do
    removal = finished_removal
    store_evidence(removal)

    get fd_member_photo_removal_path("UOTHER0001", removal)

    assert_response :not_found
  end

  test "show without member.guard serves nothing" do
    removal = finished_removal
    store_evidence(removal)
    without_member_guard
    get fd_member_photo_removal_path(MEMBER, removal)

    assert_not_equal IMAGE, response.body.b
  end
end
