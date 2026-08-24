import { Controller } from "@hotwired/stimulus"

const KEY = "mn-rail"

export default class extends Controller {
  toggle() {
    const shut = document.documentElement.classList.toggle("rail-shut")
    try {
      localStorage.setItem(KEY, shut ? "shut" : "open")
    } catch (error) {
      return
    }
  }
}
