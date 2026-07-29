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
  static values = { data: Object, tickEvery: Number }

  get tickEvery() {
    return this.hasTickEveryValue && this.tickEveryValue > 0 ? this.tickEveryValue : 15
  }

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
          x: {
            ticks: {
              autoSkip: false,
              maxRotation: 0,
              callback: (value, index) => {
                const labels = this.dataValue.labels
                if (index === labels.length - 1) return labels[index]
                return index % this.tickEvery === 0 ? labels[index] : null
              },
            },
          },
          y: { beginAtZero: true },
        },
      },
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
