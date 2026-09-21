const CACHET = "https://cachet.hackclub.com"

export function askingFor(where, term) {
  const url = new URL(where, window.location.origin)
  url.searchParams.set("q", term)
  return url
}

export function said(className, text) {
  const span = document.createElement("span")
  span.className = className
  span.textContent = text
  return span
}

export function face(id, initial) {
  const img = document.createElement("img")
  img.className = "avatar"
  img.src = `${CACHET}/users/${encodeURIComponent(id)}/r`
  img.alt = ""
  img.dataset.cachetFace = id
  img.dataset.cachetInitial = initial || "?"
  return img
}

export function named(id, name) {
  const span = said("pick-name", name)
  if (name === `@${id}`) span.dataset.cachetName = id
  return span
}

export function personRow(member, action) {
  const row = document.createElement("button")
  row.type = "button"
  row.className = "pick-opt"
  row.dataset.action = action
  row.dataset.id = member.id
  row.dataset.name = member.name
  row.dataset.initial = member.initial
  row.dataset.image = member.image || ""

  const bare = member.name.replace(/^@/, "")
  const sub = [
    member.handle && member.handle !== bare ? `@${member.handle}` : null,
    member.id !== bare ? member.id : null
  ].filter(Boolean).join(" · ")

  const body = said("pick-body-text", "")
  body.append(named(member.id, member.name), said("pick-id mono", sub))
  row.append(face(member.id, member.initial), body)
  return row
}
