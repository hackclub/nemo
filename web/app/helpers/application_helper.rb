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

  ACTIONS = {
    "acquisition" => "acquisition", "activation" => "activation",
    "response" => "answered", "retention" => "retention",
    "distribution" => "distribution"
  }.freeze

  def journey_stages
    JOURNEY
  end

  BLURBS = {
    "acquisition" => "accounts created, and how many of them get claimed",
    "activation" => "where a newcomer lands, and whether they say anything",
    "response" => "whether a first post got an answer, and how fast",
    "retention" => "whether they came back, and how far the walk has got",
    "distribution" => "how posting is spread, and who carries it"
  }.freeze

  def journey_blurb(stage)
    BLURBS.fetch(stage, "")
  end

  def journey_reach(stage)
    covered, total = journey_coverage(stage)
    return tag.span("n/a", class: "chip chip-off") if total.nil? || total.zero?
    return tag.span("complete", class: "chip chip-good") if covered >= total

    share = (covered.to_f / total * 100).round(1)
    tag.span("#{number_with_delimiter(covered)} of #{number_with_delimiter(total)}",
      class: share < 10 ? "chip chip-warn" : "chip chip-off")
  end

  def journey_coverage(stage)
    case stage
    when "activation"
      reach = Analytics::MartNewcomerChannels.order(:channel_id).first
      [reach&.searched_of_cohort, reach&.cohort_size]
    when "distribution"
      band = Analytics::MartActivityDistribution.order(:band_order).first
      [Analytics::MartActivityDistribution.sum(:members), band&.workspace_members]
    when "response"
      checked, = Analytics::MartResponseRate.totals
      [checked, checked]
    else
      [1, 1]
    end
  end
end
