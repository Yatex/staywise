import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    timeout: { type: Number, default: 3500 }
  }

  connect() {
    this.timer = window.setTimeout(() => this.dismiss(), this.timeoutValue)
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  dismiss() {
    window.clearTimeout(this.timer)
    this.element.classList.add("opacity-0", "-translate-y-2")
    window.setTimeout(() => this.element.remove(), 200)
  }
}
