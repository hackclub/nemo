require "test_helper"

class FdBlockedDomainsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def add(**params)
    post fd_blocked_domains_path, params: { domain: "throwaway.example" }.merge(params)
  end

  def member_on!(user_id, email)
    member!(user_id, email: email)
  end

  test "a domain lands on the list and starts by only writing things down" do
    add

    one = Fd::BlockedDomain.active.last
    assert_equal "throwaway.example", one.domain
    assert_equal Fd::BlockedDomain::FLAG, one.effect, "the shipped default is shadow mode"
    assert_equal Fd::BlockedDomain::EXACT, one.match_mode
  end

  test "the at sign and the case are taken off so the list holds one shape" do
    add(domain: "  @Throwaway.Example  ")

    assert_equal "throwaway.example", Fd::BlockedDomain.active.last.domain
  end

  test "something that is not a domain is refused" do
    assert_no_difference -> { Fd::BlockedDomain.count } do
      add(domain: "localhost")
    end
    assert_match(/not a domain/, flash[:alert])

    assert_no_difference -> { Fd::BlockedDomain.count } do
      add(domain: "")
    end
  end

  test "a domain a lot of members already use is refused until it is insisted on" do
    30.times { |n| member_on!("USCHOOL#{n}", "kid#{n}@school.example") }

    assert_no_difference -> { Fd::BlockedDomain.count } do
      add(domain: "school.example")
    end
    assert_equal "domain", flash[:field_error]["field"]
    assert_match(/is on 30 accounts already/, flash[:field_error]["message"])
    assert_equal "school.example", flash[:field_error]["was"]

    assert_difference -> { Fd::BlockedDomain.count }, 1 do
      add(domain: "school.example", anyway: "1")
    end
  end

  test "the way past is only offered once the refusal has been seen" do
    get fd_configuration_path(tab: "domains")
    assert_select %(input[name="anyway"]), false, "nothing to tick before it is refused"

    30.times { |n| member_on!("USCHOOL#{n}", "kid#{n}@school.example") }
    add(domain: "school.example")
    follow_redirect!

    assert_select %(input[name="anyway"])
    assert_select ".field-wrong", /is on 30 accounts already/
    assert_select %(input[name="domain"][value="school.example"])
  end

  test "a domain nobody uses goes on without argument" do
    10.times { |n| member_on!("UPLAIN#{n}", "kid#{n}@school.example") }

    assert_difference -> { Fd::BlockedDomain.count }, 1 do
      add(domain: "throwaway.example")
    end
  end

  test "deactivating on sight needs the capability to deactivate" do
    Authz::Override.create!(role: "firefighter", capability: "member.deactivate",
      allowed: false, changed_by: "UME")
    sign_in_as(hold_role!("UFF", "firefighter"))

    assert_no_difference -> { Fd::BlockedDomain.count } do
      add(effect: "deactivate")
    end
  end

  test "the same domain is not held twice" do
    add
    assert_no_difference -> { Fd::BlockedDomain.active.count } do
      add
    end
    assert_match(/Already on the list/, flash[:alert])
  end

  test "taking one off retires it rather than losing that it was there" do
    add
    one = Fd::BlockedDomain.active.last

    delete fd_blocked_domain_path(one)

    assert_not one.reload.active
    assert_equal "UME", one.retired_by
    assert_not_nil one.retired_at
  end

  test "adding and removing a domain both land in the record" do
    assert_difference -> { Fd::AuditEntry.where(entity_type: "blocked_domain").count }, 2 do
      add
      delete fd_blocked_domain_path(Fd::BlockedDomain.active.last)
    end
  end

  test "exact holds the domain, suffix holds what sits under it" do
    exact = Fd::BlockedDomain.add!(domain: "throwaway.example", by: "UME")
    assert exact.holds?("throwaway.example")
    assert_not exact.holds?("mail.throwaway.example")

    wide = Fd::BlockedDomain.add!(domain: "throwaway.example", by: "UME",
      match_mode: Fd::BlockedDomain::SUFFIX)
    assert wide.holds?("mail.throwaway.example")
    assert_not wide.holds?("notthrowaway.example")
  end

  test "the worst effect is the one that counts when two entries catch a domain" do
    Fd::BlockedDomain.add!(domain: "throwaway.example", by: "UME", effect: "flag")
    Fd::BlockedDomain.add!(domain: "throwaway.example", by: "UME",
      match_mode: "suffix", effect: "deactivate")

    assert_equal "deactivate", Fd::BlockedDomain.worst_for("throwaway.example").effect
  end

  test "the tab lists what is held and who was caught" do
    add
    as_pipeline("INSERT INTO fd.join_screen (user_id, email_domain, outcome) " \
                "VALUES (?, ?, 'flagged')", "UCAUGHT", "throwaway.example")
    seeded!("fd.join_screen", "user_id", "UCAUGHT")

    get fd_configuration_path(tab: "domains")
    assert_response :success
    assert_match "throwaway.example", response.body
    assert_select ".data-table", minimum: 2
  end
end
