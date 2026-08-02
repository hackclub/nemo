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
  Legend,
)

export default class extends Controller {
  static values = { data: Object, rates: Array }

  connect() {
    const css = getComputedStyle(document.documentElement)
    const token = (name) => css.getPropertyValue(name).trim()
    const createdColor = token("--mn-rule-strong")
    const claimedColor = token("--mn-accent")
    const rateColor = token("--flag-blue")
    const gridColor = token("--mn-rule")
    const inkColor = token("--mn-ink-2")

    const [created, claimed] = this.dataValue.datasets

    this.chart = new Chart(this.element, {
      type: "bar",
      data: {
        labels: this.dataValue.labels,
        datasets: [
          { ...created, backgroundColor: createdColor, order: 2 },
          { ...claimed, backgroundColor: claimedColor, order: 2 },
          {
            type: "line",
            label: "claim rate",
            data: this.ratesValue.map((rate) => (rate == null ? null : rate * 100)),
            yAxisID: "rate",
            borderColor: rateColor,
            backgroundColor: rateColor,
            borderWidth: 2,
            pointRadius: 3,
            tension: 0.3,
            spanGaps: false,
            order: 1,
          },
        ],
      },
      options: {
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        scales: {
          y: {
            beginAtZero: true,
            grid: { color: gridColor },
            ticks: { color: inkColor },
          },
          rate: {
            position: "right",
            beginAtZero: true,
            max: 100,
            grid: { drawOnChartArea: false },
            ticks: { color: rateColor, callback: (value) => `${value}%` },
          },
          x: {
            grid: { display: false },
            ticks: { color: inkColor },
          },
        },
        plugins: {
          legend: { display: true, labels: { color: inkColor } },
          tooltip: {
            callbacks: {
              label: (context) => {
                const value = context.parsed.y
                if (context.dataset.label === "claim rate") {
                  return `claim rate: ${value.toFixed(1)}%`
                }
                if (context.dataset.label !== "claimed within 30d") {
                  return `${context.dataset.label}: ${value}`
                }
                const rate = this.ratesValue[context.dataIndex]
                if (rate == null) return `claimed within 30d: ${value} (n/a)`
                return `claimed within 30d: ${value} (${(rate * 100).toFixed(1)}% of this cohort)`
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
