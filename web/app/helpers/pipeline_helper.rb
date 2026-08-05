module PipelineHelper
  STATUS_CHIP = {
    "ok" => "chip chip-good",
    "failed" => "chip chip-crit",
    "partial" => "chip chip-warn",
    "cancelled" => "chip chip-warn",
    "running" => "chip chip-off",
    "abandoned" => "chip chip-off"
  }.freeze

  STALE_AFTER = 36.hours

  def run_status(row)
    tag.span row.status, class: STATUS_CHIP.fetch(row.status, "chip chip-off")
  end

  def run_status_tally(statuses)
    counted = statuses.values.sum > 1
    chips = statuses.map do |status, count|
      tag.span(counted ? "#{count} #{status}" : status,
        class: STATUS_CHIP.fetch(status, "chip chip-off"))
    end
    safe_join(chips, " ")
  end

  def run_stale?(row)
    Time.current - row.age_from > STALE_AFTER
  end

  def run_age(row)
    age = "#{time_ago_in_words(row.age_from)} ago"
    return tag.span(age, class: "delta-note") unless run_stale?(row)

    tag.span("#{age}, the nightly should run daily", class: "chip chip-warn")
  end

  def output_size(text)
    bytes = text.to_s.bytesize
    return "#{bytes} B" if bytes < 1024

    format("%.1f kB", bytes / 1024.0)
  end

  def run_duration(row)
    seconds = row.seconds
    return "n/a" if seconds.nil?
    return "#{seconds}s" if seconds < 90

    minutes = seconds / 60
    return "#{minutes} min" if minutes < 90

    format("%.1f h", minutes / 60.0)
  end

  def run_rows(row)
    return "n/a" if row.rows_in.nil?

    counted = number_with_delimiter(row.rows_in)
    return counted if row.total_expected.blank?

    "#{counted} of #{number_with_delimiter(row.total_expected)}"
  end
end
