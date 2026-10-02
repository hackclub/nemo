import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { said: String }

  use() {
    const field = document.querySelector(".qsearch .qsearch-in")
    if (!field) return

    field.value = this.saidValue
    document.querySelectorAll(".modal-flip:checked").forEach((flip) => {
      flip.checked = false
    })
    field.focus()
    field.form?.requestSubmit()
  }
}
