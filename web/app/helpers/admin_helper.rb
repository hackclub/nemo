module AdminHelper
  IMPLIED = "implied by community manager, no grant row".freeze

  def role_cell(role, implied: nil)
    return tag.span(role.tr("_", " "), class: "chip") if role.present?
    return tag.span(implied, class: "chip chip-off", title: IMPLIED) if implied.present?

    tag.span("n/a", class: "sub2")
  end

  def fd_role_cell(_user_id, role, manager)
    return tag.span(Fd::Access::MANAGER_LABEL, class: "chip chip-crit") if manager

    role_cell(role)
  end

  def implied_role(user_id, family)
    return nil unless manager?(user_id)

    Community::Permission.superadmin(family)
  end

  def manager?(user_id)
    managers.include?(user_id)
  end

  def managers
    @managers ||= Staff.where(community_manager: true).pluck(:user_id)
  end

  def role_label_for(family, role)
    return Fd::Permission::ROLE_LABELS.fetch(role) if family == "fd"

    Community::Permission.role_label(role)
  end

  def permission_label_for(family, key)
    family == "fd" ? Fd::Permission.label(key) : Community::Permission.label(key)
  end

  def holds_switch(family, key, role)
    return role_switch(key, role) if family == "fd"

    holds_mark(Community::Permission.holds?(role, key))
  end

  CHANGE_WORDS = {
    ["grant", "granted"] => "Gave access",
    ["grant", "revoked"] => "Took access back",
    ["permission", "granted"] => "Gave to a role",
    ["permission", "revoked"] => "Took from a role",
    ["flag", "turned_on"] => "Turned a section on",
    ["flag", "turned_off"] => "Turned a section off",
    ["channel_audience", "granted"] => "Opened a channel up",
    ["channel_audience", "revoked"] => "Made a channel private"
  }.freeze

  def change_head(entry)
    CHANGE_WORDS.fetch([entry.entity_type, entry.verb], entry.verb.tr("_", " ").capitalize)
  end

  def change_said(entry)
    said = entry.after || {}
    case entry.entity_type
    when "grant" then [names[said["user_id"]], said["role"]].compact.join(", ").presence
    when "permission" then [said["permission"], said["role"]].compact.join(" · ").presence
    when "flag" then said["flag"]
    when "channel_audience" then channel_label(entry.entity_id)
    end || tag.span("n/a", class: "sub2")
  end

  AUDIENCE_TONE = { "everyone" => "chip chip-warn", "shared" => "chip" }.freeze

  AUDIENCE_NOTE = {
    "private" => "only curators and the people you name",
    "shared" => "anyone with member analytics",
    "everyone" => "anyone signed in, no grant needed"
  }.freeze

  FACES_SHOWN = 4

  def audience_chip(kind)
    tone = AUDIENCE_TONE[kind]
    return tag.span(kind, class: "sub2") if tone.nil?

    tag.span(kind, class: tone)
  end

  def named_faces(named, kind)
    return tag.span("anyone signed in", class: "sub2") if kind == "everyone"
    return tag.span("nobody", class: "sub2") if named.empty?

    shown = named.first(FACES_SHOWN)
    stack = tag.span(class: "face-stack") do
      safe_join(shown.map { |grant| face(grant.user_id) })
    end
    return stack if named.size <= FACES_SHOWN

    stack + tag.span("+#{named.size - FACES_SHOWN}", class: "chip chip-off")
  end

  def acted_bar(count, busiest)
    return tag.span("never", class: "sub2") if count.to_i.zero?

    width = busiest.to_i.positive? ? (count * 100.0 / busiest).round : 0
    tag.span(class: "inbar") do
      tag.span(tag.i(nil, style: "width: #{width}%")) + tag.span(count)
    end
  end
end
