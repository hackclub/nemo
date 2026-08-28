module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def on?(key)
    Fd::Flag.on?(key)
  end

  JOURNEY = [
    ["01", "Acquisition", "acquisition"],
    ["02", "Activation", "activation"],
    ["03", "Response", "response"],
    ["04", "Retention", "retention"],
    ["05", "Distribution", "distribution"]
  ].freeze

  def journey_stages
    JOURNEY
  end
end
