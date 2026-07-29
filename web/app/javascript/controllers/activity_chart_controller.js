import { Controller } from "@hotwired/stimulus"
import {
  Chart,
  LineController,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from "chart.js"

Chart.register(LineController, LineElement, PointElement, CategoryScale, LinearScale, Tooltip, Legend)

export default class extends Controller {
  static values = { data: Object }

  connect() {
    this.chart = new Chart(this.element, {
      type: "line",
      data: this.dataValue,
      options: {
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        elements: { point: { radius: 0, hitRadius: 8 }, line: { borderWidth: 2, tension: 0.2 } },
        plugins: { legend: { display: true } },
        scales: {
          x: { ticks: { maxTicksLimit: 8, autoSkip: true } },
          y: { beginAtZero: true },
        },
      },
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
