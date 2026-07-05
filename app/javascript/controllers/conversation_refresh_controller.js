import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["messages", "alerts", "status"]
  static values = {
    interval: { type: Number, default: 5000 },
    url: String,
  }

  connect() {
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async refresh() {
    if (document.hidden) return

    const response = await fetch(this.urlValue || window.location.href, {
      headers: { Accept: "text/html" },
    })
    if (!response.ok) return

    const html = await response.text()
    const documentFragment = new DOMParser().parseFromString(html, "text/html")

    this.replaceTarget("messages", documentFragment)
    this.replaceTarget("alerts", documentFragment)
    this.replaceTarget("status", documentFragment)
  }

  replaceTarget(name, documentFragment) {
    const current = this[`${name}Target`]
    const next = documentFragment.querySelector(`[data-conversation-refresh-target="${name}"]`)

    if (current && next && current.innerHTML !== next.innerHTML) {
      current.innerHTML = next.innerHTML
    }
  }
}
