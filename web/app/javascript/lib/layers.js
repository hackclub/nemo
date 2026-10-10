const POPUPS = ":popover-open, details.menu[open], details.picker[open]"
const DRAWER = "[data-controller~='person-drawer']"
const PALETTE = ".palette-host"
const DIALOG = "dialog[open]"
const OVERLAYS = `.modal-wrap, .modal-veil, ${DRAWER}, ${PALETTE}, ${DIALOG}`

const stack = []

export function raise(layer) {
  lower(layer)
  stack.push(layer)
}

export function lower(layer) {
  const at = stack.indexOf(layer)
  if (at >= 0) stack.splice(at, 1)
}

export function depth(layer) {
  return stack.indexOf(layer)
}

export function topmost(layer) {
  return stack.length > 0 && stack[stack.length - 1] === layer
}

export function modalsOpen() {
  return stack.length
}

export function popupOpen(root = document) {
  return root.querySelector(POPUPS) !== null
}

export function aboveOpen() {
  return document.querySelector(`${PALETTE}:not([hidden]), ${DIALOG}`) !== null
}

export function drawerOpen() {
  return document.querySelector(`${DRAWER}:not(:empty)`) !== null
}

export function inDrawer(target) {
  return target instanceof Element && target.closest(DRAWER) !== null
}

export function inAbove(target) {
  return target instanceof Element && target.closest(`${PALETTE}, ${DIALOG}`) !== null
}

export function inOverlay(target) {
  return target instanceof Element && target.closest(OVERLAYS) !== null
}
