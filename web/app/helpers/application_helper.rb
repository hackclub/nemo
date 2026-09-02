module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def held_label(staff)
    return Fd::Access::MANAGER_LABEL if Fd::Access.manager?(staff)
    return "no access" if staff.nil?

    roles = Authz.roles_held(staff.user_id)
    return "no access" if roles.empty?

    roles.map { |role| Authz.role_label(role) }.to_sentence
  end

  def on?(key)
    Fd::Flag.on?(key)
  end

  JOURNEY = [
    ["Joining", "joining"],
    ["Newcomers", "newcomers"],
    ["Getting replies", "replies"],
    ["Coming back", "returning"],
    ["Who is active", "active"]
  ].freeze

  ACTIONS = {
    "joining" => "acquisition", "newcomers" => "activation",
    "replies" => "replies", "returning" => "retention",
    "active" => "distribution"
  }.freeze

  MOVED = {
    "acquisition" => "joining", "activation" => "newcomers",
    "response" => "replies", "retention" => "returning",
    "distribution" => "active"
  }.freeze

  def journey_stages
    JOURNEY
  end
end
