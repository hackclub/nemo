module FdHelper
  AGE_WARN = 2.days
  AGE_CRIT = 5.days

  def case_age_chip(opened_at)
    age = Time.current - opened_at
    tone =
      if age >= AGE_CRIT
        "chip-crit"
      elsif age >= AGE_WARN
        "chip-warn"
      else
        "chip-off"
      end
    tag.span(case_age_label(age), class: "chip #{tone}")
  end

  def case_age_label(seconds)
    days = (seconds / 1.day).floor
    return "#{days}d" if days.positive?

    hours = (seconds / 1.hour).floor
    return "#{hours}h" if hours.positive?

    "#{(seconds / 1.minute).floor}m"
  end

  def tenure_label(days)
    return "n/a" if days.nil?
    return "#{days}d" if days < 31

    months = days / 30
    return "#{months}mo" if months < 12

    years, rest = months.divmod(12)
    rest.zero? ? "#{years}y" : "#{years}y #{rest}mo"
  end

  SLACK_ARCHIVES = "https://hackclub.slack.com/archives".freeze

  ROLE_LABELS = {
    "target" => "on the receiving end",
    "reporter" => "reported it",
    "witness" => "was in the thread",
    "participant" => "was in the thread"
  }.freeze

  def slack_thread_url(channel_id, thread_ts)
    "#{SLACK_ARCHIVES}/#{channel_id}/p#{thread_ts.delete('.')}"
  end

  def role_label(role)
    ROLE_LABELS.fetch(role, role)
  end

  def case_status_chip(kase)
    if kase.resolved?
      tag.span(kase.resolution.tr("_", " "), class: "chip chip-off")
    else
      tag.span("open", class: "chip chip-crit")
    end
  end

  def subject_context_line(context)
    return "nobody identified yet" if context.nil?
    return "not in the warehouse yet" unless context.known?

    parts = [tenure_label(context.tenure_days)]
    if context.messages_posted
      parts << "#{number_with_delimiter(context.messages_posted)} messages"
    end
    parts << "#{context.channels_joined} channels" if context.channels_joined
    parts.join(" · ")
  end
end
