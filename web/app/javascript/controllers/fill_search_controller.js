import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { term: String }

  use() {
    const field = document.querySelector(".queue-search .queue-search-input")
    if (!field) return

    field.value = this.termValue
    document.querySelectorAll(".modal-flip:checked").forEach((flip) => {
      flip.checked = false
    })
    field.focus()
    field.form?.requestSubmit()
  }
}
