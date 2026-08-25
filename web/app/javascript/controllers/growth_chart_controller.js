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
  Legend,
)

export default class extends ThemedChartController {
  static values = { data: Object, rates: Array }

  draw() {
    const p = palette()
    const [created, claimed] = this.dataValue.datasets

    this.chart = new Chart(this.element, {
      type: "bar",
      data: {
        labels: this.dataValue.labels,
        datasets: [
          { ...created, backgroundColor: p.series[0], borderRadius: 2, order: 2 },
          { ...claimed, backgroundColor: p.series[1], borderRadius: 2, order: 2 },
          {
            type: "line",
            label: "claim rate",
            data: this.ratesValue.map((rate) => (rate == null ? null : rate * 100)),
            yAxisID: "rate",
            borderColor: p.ink2,
            backgroundColor: p.ink2,
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
            grid: { color: p.lineSoft },
            border: { display: false },
            ticks: { color: p.ink3 },
          },
          rate: {
            position: "right",
            beginAtZero: true,
            max: 100,
            grid: { drawOnChartArea: false },
            border: { display: false },
            ticks: { color: p.ink2, callback: (value) => `${value}%` },
          },
          x: {
            grid: { display: false },
            border: { display: false },
            ticks: { color: p.ink3 },
          },
        },
        plugins: {
          legend: {
            display: true,
            labels: { color: p.ink3, boxWidth: 8, boxHeight: 8, usePointStyle: true, pointStyle: "circle" },
          },
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
}
