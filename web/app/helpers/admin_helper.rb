module AdminHelper
  def role_capability_switch(role, key, override)
    held = override ? override.allowed : Authz.baseline(role).include?(key)
    label = "#{Authz.role_label(role)}: #{key}"
    why = Authz.locked?(key) ? "#{key} is FD only, it cannot be moved" : why_not("access.grant")
    if why
      return tag.span(class: "switch", role: "switch", tabindex: "0", title: why,
        aria: { checked: held.to_s, disabled: "true", label: label, description: why })
    end

    button_to held ? "On" : "Off",
      fd_role_permission_path(role: role, key: key, allowed: held ? "0" : "1"),
      method: :patch, class: "switch", form: { class: "contents" },
      role: "switch", aria: { checked: held.to_s, label: label }
  end

  def role_standing(user_id, roles: nil, extras: nil)
    roles ||= Authz.roles_held(user_id)
    extras ||= Authz::Grant.live.for_person(user_id).capabilities.where(effect: "allow").count
    text = roles.any? ? roles.map { |role| Authz.role_label(role) }.to_sentence : "No role"

    parts = [tag.span(text, class: roles.any? ? "" : "sub2")]
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
    tag.span(kind.to_s.upcase_first, class: AUDIENCE_TONE.fetch(kind, "chip chip-off"),
      title: AUDIENCE_NOTE[kind])
  end

  def named_faces(named, kind)
    return tag.span("Anyone signed in", class: "sub") if
      Channels::Audience::OPEN.include?(kind)

    people = named.select { |grant| grant.user_id.present? }
    roles = named.filter_map { |grant| grant.role.presence }.uniq
    return tag.span("Nobody", class: "sub") if people.empty? && roles.empty?

    safe_join([role_chips(roles), face_stack(people)].compact, " ")
  end

  def role_label_text(role)
    Authz.role_names.include?(role.to_s) ? Authz.role_label(role).downcase : role.to_s
  end

  def role_chips(roles)
    return nil if roles.empty?

    safe_join(roles.map { |role| tag.span("#{role_label_text(role).upcase_first} set", class: "chip") }, " ")
  end

  def face_stack(people)
    return nil if people.empty?

    shown = people.first(FACES_SHOWN)
    stack = tag.span(class: "avatar-stack") do
      safe_join(shown.map { |grant| face(grant.user_id) })
    end
    return stack if people.size <= FACES_SHOWN

    stack + tag.span("+#{people.size - FACES_SHOWN}", class: "chip chip-off")
  end

  def channel_cell(channel_id, named)
    marks = [tag.span(channel_id)]
    marks << tag.span("· private") if named&.visibility == "private"
    marks << tag.span("· archived") if named&.archived

    tag.span(class: "two-line") do
      tag.b("##{named&.name.presence || channel_id}") +
        tag.span(safe_join(marks, " "), class: "mono")
    end
  end

  def acted_bar(count, busiest)
    return tag.span("Never", class: "sub") if count.to_i.zero?

    width = busiest.to_i.positive? ? (count * 100.0 / busiest).round : 0
    tag.span(class: "inbar") do
      tag.span(tag.i(nil, style: "width: #{width}%")) + tag.span(count)
    end
  end

  JOIN_MODES = {
    Fd::AppSetting::ON => "All public",
    Fd::AppSetting::GUARDED => "Guarded only",
    Fd::AppSetting::OFF => "None"
  }.freeze

  JOIN_NOTES = {
    Fd::AppSetting::ON => "Every public channel",
    Fd::AppSetting::GUARDED => "Only channels with a guard",
    Fd::AppSetting::OFF => "No channel"
  }.freeze

  def admin_join_mode_switch(mode)
    form_with(url: admin_settings_join_mode_path, method: :post, class: "segmented") do
      safe_join(JOIN_MODES.map { |key, label|
        button_tag(label, name: "mode", value: key, "aria-pressed": (key == mode).to_s)
      })
    end
  end
end
