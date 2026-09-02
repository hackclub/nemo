module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def fd_role_label(staff)
    return Fd::Access::MANAGER_LABEL if Fd::Access.manager?(staff)

    staff&.role&.tr("_", " ")&.titleize
  end

  def held_label(staff)
    return Fd::Access::MANAGER_LABEL if Fd::Access.manager?(staff)

    held = [staff&.role, *Community::Access.held(staff).values].compact
    return "no access" if held.empty?

    held.map { |role| role.tr("_", " ") }.to_sentence.upcase_first
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
