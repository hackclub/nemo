module ClusterHelper
  MAP_RADIUS = 140
  NODE_RADIUS = 18
  LABEL_GAP = 34
  MARGIN = 60
  CROWDED = 16
  PACKED = 30
  NODE_GAP = 10
  SPOKE_GAP = 6
  SPOKE_ROOM = 125
  PULL = 0.2
  DISC = 60
  DISC_NODE = 12
  DISC_GAP = 5
  DISC_MARGIN = 24
  GOLDEN = Math::PI * (3 - Math.sqrt(5))
  SERIES = 6
  APART = %w[different_people household].freeze

  MapLayout = Struct.new(:size, :centre, :node, :crowded, :packed, :pull, :points, keyword_init: true)

  def cluster_layout(cluster)
    count = [cluster.members.size, 1].max
    return disc_layout(cluster, count) if count > DISC

    crowded = count > CROWDED
    node = node_radius(count)
    ring = [MAP_RADIUS, count * ((2 * node) + NODE_GAP) / (2 * Math::PI)].max
    half = crowded ? ring + node + SPOKE_GAP + SPOKE_ROOM : ring + MARGIN
    points = cluster.members.each_with_index.to_h do |one, at|
      angle = (-Math::PI / 2) + (2 * Math::PI * at / count)
      [one.user_id, map_point(angle, ring, half, node, crowded).merge(step: at)]
    end
    MapLayout.new(size: (2 * half).round, centre: half, node: node, crowded: crowded, packed: false,
      pull: PULL, points: points)
  end

  def disc_layout(cluster, count)
    step = ((2 * DISC_NODE) + DISC_GAP) / Math.sqrt(Math::PI)
    half = (step * Math.sqrt(count)) + DISC_NODE + DISC_MARGIN
    points = cluster.members.each_with_index.to_h do |one, at|
      reach = step * Math.sqrt(at + 0.5)
      x = half + (reach * Math.cos(at * GOLDEN))
      y = half + (reach * Math.sin(at * GOLDEN))
      [one.user_id, { x: x, y: y, lx: x, ly: y - DISC_NODE - 6, anchor: "middle", turn: 0, step: at }]
    end
    MapLayout.new(size: (2 * half).round, centre: half, node: DISC_NODE, crowded: true, packed: true,
      pull: 1.0, points: points)
  end

  def node_radius(count)
    return 11 if count > PACKED
    return 14 if count > CROWDED

    NODE_RADIUS
  end

  def map_point(angle, ring, half, node, crowded)
    cos = Math.cos(angle)
    sin = Math.sin(angle)
    point = { x: half + (ring * cos), y: half + (ring * sin) }
    return point.merge(lx: half + ((ring + LABEL_GAP) * cos), ly: half + ((ring + LABEL_GAP) * sin),
      anchor: label_anchor(cos), turn: 0) unless crowded

    out = ring + node + SPOKE_GAP
    degrees = angle * 180 / Math::PI
    point.merge(lx: half + (out * cos), ly: half + (out * sin),
      anchor: cos.negative? ? "end" : "start", turn: cos.negative? ? degrees + 180 : degrees)
  end

  def cluster_edge_path(layout, a, b)
    centre = layout.centre
    cx = centre + ((((a[:x] + b[:x]) / 2) - centre) * layout.pull)
    cy = centre + ((((a[:y] + b[:y]) / 2) - centre) * layout.pull)
    format("M%<ax>.1f %<ay>.1f Q%<cx>.1f %<cy>.1f %<bx>.1f %<by>.1f",
      ax: a[:x], ay: a[:y], cx: cx, cy: cy, bx: b[:x], by: b[:y])
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
