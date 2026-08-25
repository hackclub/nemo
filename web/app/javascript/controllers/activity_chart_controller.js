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
import { ThemedChartController, palette } from "controllers/chart_theme"

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

export default class extends ThemedChartController {
  static values = { data: Object, tickEvery: Number }

  get tickEvery() {
    return this.hasTickEveryValue && this.tickEveryValue > 0 ? this.tickEveryValue : 15
  }

  get hasRatioAxis() {
    return (this.dataValue.datasets || []).some((d) => d.yAxisID === "y1")
  }

  draw() {
    const p = palette()
    const series = p.series
    let bars = 0

    const datasets = (this.dataValue.datasets || []).map((set) => {
      if (set.yAxisID === "y1") {
        return { borderColor: p.ink2, backgroundColor: p.ink2, ...set }
      }
      const color = series[bars] || p.ink3
      bars += 1
      return { backgroundColor: color, borderRadius: 2, ...set }
    })

    const scales = {
      x: {
        ticks: {
          color: p.ink3,
          autoSkip: false,
          maxRotation: 0,
          callback: (value, index) => {
            const labels = this.dataValue.labels
            if (index === labels.length - 1) return labels[index]
            return index % this.tickEvery === 0 ? labels[index] : null
          },
        },
        grid: { display: false },
        border: { display: false },
      },
      y: {
        beginAtZero: true,
        position: "left",
        ticks: { color: p.ink3 },
        grid: { color: p.lineSoft },
        border: { display: false },
      },
    }

    if (this.hasRatioAxis) {
      scales.y1 = {
        position: "right",
        min: 0,
        max: 100,
        grid: { drawOnChartArea: false },
        border: { display: false },
        ticks: { color: p.ink2, callback: (value) => `${value}%` },
      }
    }

    this.chart = new Chart(this.element, {
      type: "bar",
      data: { labels: this.dataValue.labels, datasets: datasets },
      options: {
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        datasets: { bar: { categoryPercentage: 0.9, barPercentage: 0.9 } },
        plugins: {
          legend: { display: true, labels: { color: p.ink3, boxWidth: 8, boxHeight: 8, usePointStyle: true, pointStyle: "circle" } },
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
}
