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

  def role_capability_switch(role, key, override)
    held = override ? override.allowed : Authz.baseline(role).include?(key)
    return tag.span("&mdash;".html_safe, class: "sub2") if Authz.locked?(key)

    gated_button "access.grant", held ? "on" : "off",
      fd_role_permission_path(role: role, key: key, allowed: held ? "0" : "1"),
      method: :patch,
      class: held ? "btn btn-on" : "btn btn-off"
  end

  def role_standing(user_id, roles: nil, extras: nil)
    roles ||= Authz.roles_held(user_id)
    extras ||= Authz::Grant.live.for_person(user_id).capabilities.where(effect: "allow").count
    said = roles.any? ? roles.map { |role| Authz.role_label(role) }.to_sentence : "No role"

    parts = [tag.span(said, class: roles.any? ? "" : "sub2")]
    if extras.positive?
      parts << tag.span("with #{pluralize(extras, 'extra scope')}", class: "chip chip-good")
    end
    safe_join(parts, " ")
  end

  ROLE_NOTES = {
    "community_manager" => "Everything, including handing access out",
    "firefighter" => "Works cases, writes decisions",
    "promethean" => "Reads the channels you name to them",
    "gardener" => "Reads one shared set of channels"
  }.freeze

  def role_note(name)
    ROLE_NOTES.fetch(name.to_s, "")
  end

  CHANGE_WORDS = {
    ["grant", "granted"] => "Gave access",
    ["grant", "revoked"] => "Took access back",
    ["community_grant", "granted"] => "Gave community access",
    ["community_grant", "revoked"] => "Took community access back",
    ["capability_grant", "granted"] => "Gave one capability",
    ["capability_grant", "revoked"] => "Took one capability away",
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
    when "grant", "community_grant"
      [names[said["user_id"]], said["role"]].compact.join(", ").presence
    when "capability_grant"
      [names[said["user_id"]], said["capability"]].compact.join(", ").presence
    when "permission" then [said["permission"], said["role"]].compact.join(" · ").presence
    when "flag" then said["flag"]
    when "channel_audience" then channel_label(entry.entity_ref)
    end || tag.span("n/a", class: "sub2")
  end

  AUDIENCE_TONE = { "public" => "chip chip-warn", "everyone" => "chip chip-warn" }.freeze

  AUDIENCE_NOTE = {
    "granted" => "only the people you name",
    "private" => "only the people you name",
    "shared" => "only the people you name",
    "public" => "anyone signed in, no grant needed",
    "everyone" => "anyone signed in, no grant needed"
  }.freeze

  FACES_SHOWN = 4

  def audience_chip(kind)
    tone = AUDIENCE_TONE[kind]
    return tag.span(kind, class: "sub2") if tone.nil?

    tag.span(kind, class: tone)
  end

  def named_faces(named, kind)
    return tag.span("anyone signed in", class: "sub2") if
      Channels::Audience::OPEN.include?(kind)

    people = named.select { |grant| grant.user_id.present? }
    roles = named.filter_map { |grant| grant.role.presence }.uniq
    return tag.span("nobody", class: "sub2") if people.empty? && roles.empty?

    safe_join([role_chips(roles), face_stack(people)].compact, " ")
  end

  def role_said(role)
    Authz.role_names.include?(role.to_s) ? Authz.role_label(role).downcase : role.to_s
  end

  def role_chips(roles)
    return nil if roles.empty?

    safe_join(roles.map { |role| tag.span("#{role_said(role)} set", class: "chip") }, " ")
  end

  def face_stack(people)
    return nil if people.empty?

    shown = people.first(FACES_SHOWN)
    stack = tag.span(class: "face-stack") do
      safe_join(shown.map { |grant| face(grant.user_id) })
    end
    return stack if people.size <= FACES_SHOWN

    stack + tag.span("+#{people.size - FACES_SHOWN}", class: "chip chip-off")
  end

  def acted_bar(count, busiest)
    return tag.span("never", class: "sub2") if count.to_i.zero?

    width = busiest.to_i.positive? ? (count * 100.0 / busiest).round : 0
    tag.span(class: "inbar") do
      tag.span(tag.i(nil, style: "width: #{width}%")) + tag.span(count)
    end
  end
end
