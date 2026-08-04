module PipelineHelper
  STATUS_CLASS = {
    "ok" => "mn-text-success",
    "failed" => "mn-text-danger",
    "partial" => "mn-text-danger",
    "running" => "mn-label",
    "abandoned" => "mn-label"
  }.freeze

  STALE_AFTER = 36.hours

  def run_status(row)
    tag.span row.status, class: STATUS_CLASS.fetch(row.status, "mn-label")
  end

  def run_stale?(row)
    Time.current - (row.finished_at || row.started_at) > STALE_AFTER
  end

  def run_age(row)
    age = "#{time_ago_in_words(row.finished_at || row.started_at)} ago"
    return tag.span(age, class: "mn-label") unless run_stale?(row)

    tag.span("#{age}, the nightly should run daily", class: "mn-text-danger")
  end

  def run_duration(row)
    seconds = row.seconds
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

  def run_progress_pct(row)
    return nil if row.progress_share.blank?

    (row.progress_share.to_f * 100).round(1)
  end
end
