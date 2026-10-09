module ClusterHelper
  MAP_SIZE = 400
  MAP_RADIUS = 140
  NODE_RADIUS = 18
  LABEL_GAP = 34
  SERIES = 6
  APART = %w[different_people household].freeze

  def cluster_points(cluster)
    count = [cluster.members.size, 1].max
    centre = MAP_SIZE / 2.0
    cluster.members.each_with_index.to_h do |one, at|
      angle = (-Math::PI / 2) + (2 * Math::PI * at / count)
      [one.user_id, { x: centre + (MAP_RADIUS * Math.cos(angle)), y: centre + (MAP_RADIUS * Math.sin(angle)),
                      lx: centre + ((MAP_RADIUS + LABEL_GAP) * Math.cos(angle)),
                      ly: centre + ((MAP_RADIUS + LABEL_GAP) * Math.sin(angle)),
                      anchor: label_anchor(Math.cos(angle)), step: at }]
    end
  end

  def label_anchor(cos)
    return "middle" if cos.abs < 0.3

    cos.positive? ? "start" : "end"
  end

  def cluster_edge_class(edge)
    ["edge", "edge-#{edge_band(edge.score)}", edge_tone(edge.verdict)].compact.join(" ")
  end

  def edge_band(score)
    return "verdict" if score.nil?
    return "certain" if score >= Fd::MemberLink::CERTAIN
    return "strong" if score >= Fd::MemberLink::STRONG

    "worth"
  end

  def edge_tone(verdict)
    return nil if verdict.blank?

    APART.include?(verdict) ? "edge-apart" : "edge-together"
  end

  def cluster_edge_title(edge)
    parts = [person_label(edge.a_user_id), person_label(edge.b_user_id)].join(" and ")
    said = edge.score ? number_with_precision(edge.score, precision: 1) : nil
    verdict = edge.verdict&.tr("_", " ")
    [parts, said, verdict].compact.join(", ")
  end

  def person_label(user_id)
    names[user_id].to_s.presence || user_id
  end

  def cluster_days(cluster)
    (cluster.since.to_date..Time.current.to_date).to_a
  end

  def cluster_sightings(cluster)
    @cluster_sightings ||= cluster.sightings.group_by { |one| [one.user_id, one.hour.to_date] }
  end

  def shared_tone(cluster, ip)
    at = cluster.shared_ips.index(ip)
    at && "var(--series-#{at % SERIES})"
  end

  def cluster_cell(cluster, user_id, day)
    seen = cluster_sightings(cluster)[[user_id, day]] || []
    return tag.i(class: "none") if seen.empty?

    shared = seen.map(&:ip).find { |ip| cluster.shared_ips.include?(ip) }
    rows = seen.group_by(&:ip).map do |ip, hours|
      { label: ip, value: hours.map { |one| one.hour.strftime("%H:00") }.uniq.join(", "),
        tone: shared_tone(cluster, ip) || "var(--muted-foreground)" }
    end
    tip = { title: "#{person_label(user_id)}, #{day.strftime('%-d %b')}", rows: rows }.to_json
    tag.i(class: shared ? "shared" : "own", style: ("background: #{shared_tone(cluster, shared)}" if shared),
      tabindex: 0, role: "img", data: { tip: tip }, aria: { label: "#{day.strftime('%-d %b')}, seen" })
  end
end
