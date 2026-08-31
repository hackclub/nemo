module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def on?(key)
    Fd::Flag.on?(key)
  end

  JOURNEY = [
    ["Joining", "acquisition"],
    ["Newcomers", "activation"],
    ["Getting replies", "response"],
    ["Coming back", "retention"],
    ["Who is active", "distribution"]
  ].freeze

  ACTIONS = {
    "acquisition" => "acquisition", "activation" => "activation",
    "response" => "answered", "retention" => "retention",
    "distribution" => "distribution"
  }.freeze

  def journey_stages
    JOURNEY
  end
end
