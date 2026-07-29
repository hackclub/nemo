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
  static values = { data: Object }

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
                const invited = context.chart.data.datasets[0].data[context.dataIndex]
                const pct = invited ? ((value / invited) * 100).toFixed(1) : "n/a"
                return `claimed: ${value} (${pct}%)`
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
