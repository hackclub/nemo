import { Controller } from "@hotwired/stimulus"
import {
  Chart,
  BarController,
  BarElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from "chart.js"

Chart.register(BarController, BarElement, CategoryScale, LinearScale, Tooltip, Legend)

export default class extends Controller {
  static values = { type: String, data: Object, options: Object }

  connect() {
    this.chart = new Chart(this.element, {
      type: this.typeValue,
      data: this.dataValue,
      options: this.optionsValue,
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
