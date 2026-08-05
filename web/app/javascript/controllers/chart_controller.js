import {
  Chart,
  BarController,
  BarElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from "chart.js"
import { ThemedChartController, palette } from "controllers/chart_theme"

Chart.register(BarController, BarElement, CategoryScale, LinearScale, Tooltip, Legend)

export default class extends ThemedChartController {
  static values = { type: String, data: Object, options: Object }

  draw() {
    const p = palette()

    const data = {
      ...this.dataValue,
      datasets: this.dataValue.datasets.map((set) => ({
        backgroundColor: p.accent,
        borderRadius: 3,
        ...set,
      })),
    }

    const axis = {
      ticks: { color: p.ink3 },
      grid: { color: p.lineSoft },
      border: { display: false },
    }

    this.chart = new Chart(this.element, {
      type: this.typeValue,
      data: data,
      options: {
        interaction: { mode: "index", intersect: false },
        hover: { mode: "index", intersect: false },
        ...this.optionsValue,
        scales: { x: axis, y: axis, ...(this.optionsValue.scales || {}) },
      },
    })
  }
}
