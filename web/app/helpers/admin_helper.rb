module AdminHelper
  def role_capability_switch(role, key, override)
    held = override ? override.allowed : Authz.baseline(role).include?(key)
    return dead_button(held ? "on" : "off", "#{key} is FD only, it cannot be moved") if Authz.locked?(key)

    gated_button "access.grant", held ? "on" : "off",
      fd_role_permission_path(role: role, key: key, allowed: held ? "0" : "1"),
      method: :patch,
      class: held ? "btn btn-on" : "btn tog-off"
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
    "firefighter" => "Works cases",
    "promethean" => "Reads the channels you name to them",
    "gardener" => "Reads one shared set of channels"
  }.freeze

  def role_note(name)
    ROLE_NOTES.fetch(name.to_s, "")
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
