import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const BEAT_EVERY = 30_000

export default class extends Controller {
  static values = { case: Number, me: String }

  async connect() {
    this.gone = false
    this.hideMe = this.hideMe.bind(this)
    this.watch = new MutationObserver(this.hideMe)
    this.watch.observe(this.element, { childList: true, subtree: true })
    this.hideMe()

    const subscription = await cable.subscribeTo(
      { channel: "CaseChatPresenceChannel", case_id: this.caseValue }, {}
    )
    if (this.gone) return subscription.unsubscribe()

    this.subscription = subscription
    this.beating = setInterval(() => subscription.perform("beat"), BEAT_EVERY)
  }

  disconnect() {
    this.gone = true
    if (this.beating) clearInterval(this.beating)
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
