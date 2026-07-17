import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "warning"]
  static values = { used: Number }

  connect() {
    this.updateWarning()
  }

  updateWarning() {
    this.warningTarget.classList.toggle("hidden", !this.belowCurrentUsage())
  }

  confirm(event) {
    if (this.belowCurrentUsage() && !window.confirm("La cuenta ya usa más propiedades que este límite. Las propiedades existentes se conservarán, pero no se podrán crear nuevas. ¿Querés continuar?")) {
      event.preventDefault()
    }
  }

  belowCurrentUsage() {
    const rawValue = this.inputTarget.value.trim()
    return rawValue !== "" && Number(rawValue) < this.usedValue
  }
}
