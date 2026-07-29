import { Controller } from "@hotwired/stimulus"
import {
  Chart,
  BarController,
  BarElement,
  LineController,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from "chart.js"

Chart.register(
  BarController,
  BarElement,
  LineController,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend
)

export default class extends Controller {
  static values = { data: Object, tickEvery: Number }

  get tickEvery() {
    return this.hasTickEveryValue && this.tickEveryValue > 0 ? this.tickEveryValue : 15
  }

  get hasRatioAxis() {
    return (this.dataValue.datasets || []).some((d) => d.yAxisID === "y1")
  }

  connect() {
    const scales = {
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
      y: { beginAtZero: true, position: "left" },
    }

    if (this.hasRatioAxis) {
      scales.y1 = {
        position: "right",
        min: 0,
        max: 100,
        grid: { drawOnChartArea: false },
        ticks: { callback: (value) => `${value}%` },
      }
    }

    this.chart = new Chart(this.element, {
      type: "bar",
      data: this.dataValue,
      options: {
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        datasets: { bar: { categoryPercentage: 0.9, barPercentage: 0.9 } },
        plugins: {
          legend: { display: true },
          tooltip: {
            callbacks: {
              label: (context) => {
                const value = context.parsed.y
                if (context.dataset.yAxisID === "y1") {
                  return `${context.dataset.label}: ${value.toFixed(1)}%`
                }
                return `${context.dataset.label}: ${value.toLocaleString()}`
              },
            },
          },
        },
        scales,
      },
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
