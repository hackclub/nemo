import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { case: Number, me: String }

  async connect() {
    this.hideMe = this.hideMe.bind(this)
    this.watch = new MutationObserver(this.hideMe)
    this.watch.observe(this.element, { childList: true, subtree: true })
    this.hideMe()

    this.subscription = await cable.subscribeTo(
      { channel: "CaseChatPresenceChannel", case_id: this.caseValue }, {}
    )
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
    if (this.watch) this.watch.disconnect()
  }

  hideMe() {
    const box = this.element.querySelector(".chat-here")
    if (!box) return

    const others = []
    box.querySelectorAll("[data-user]").forEach((who) => {
      const me = who.dataset.user === this.meValue
      who.hidden = me
      if (!me) others.push(who.dataset.name)
    })
    box.hidden = others.length === 0
    box.title = this.sentence(others)
  }

  sentence(names) {
    if (names.length === 0) return ""
    if (names.length === 1) return `${names[0]} is on this case`
    return `${names.slice(0, -1).join(", ")} and ${names.at(-1)} are on this case`
  }
}
