import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

eagerLoadControllersFrom("controllers", application)

const chartPaths = Object.keys(
  JSON.parse(document.querySelector("script[type=importmap]").text).imports
).filter((path) => /^charts\/.*_controller$/.test(path))

const waiting = new Map(chartPaths.map((path) => [
  path.replace(/^charts\//, "").replace(/_controller$/, "").replace(/_/g, "-"),
  path
]))

let watcher = null

function drawn(name) {
  return document.querySelector(`[data-controller~="${name}"]`) !== null
}

function registerDrawnCharts() {
  for (const [name, path] of waiting) {
    if (!drawn(name)) continue

    waiting.delete(name)
    import(path)
      .then((module) => application.register(name, module.default))
      .catch((error) => console.error(`Failed to register chart controller: ${name} (${path})`, error))
  }
  if (waiting.size === 0 && watcher) {
    watcher.disconnect()
    watcher = null
  }
}

registerDrawnCharts()

if (waiting.size > 0) {
  watcher = new MutationObserver(registerDrawnCharts)
  watcher.observe(document.documentElement, {
    attributeFilter: ["data-controller"],
    subtree: true,
    childList: true
  })
}
