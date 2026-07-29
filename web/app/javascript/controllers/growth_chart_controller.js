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
  static values = { data: Object, rates: Array }

  connect() {
    this.chart = new Chart(this.element, {
      type: "bar",
      data: this.dataValue,
      options: {
        maintainAspectRatio: false,
        plugins: {
          legend: { display: true },
          tooltip: {
            callbacks: {
              label: (context) => {
                const value = context.parsed.y
                if (context.dataset.label !== "claimed") return `${context.dataset.label}: ${value}`
                const rate = this.ratesValue[context.dataIndex]
                if (rate == null) return `claimed: ${value} (n/a)`
                return `claimed: ${value} (${(rate * 100).toFixed(1)}% of this cohort)`
              },
            },
          },
        },
      },
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
