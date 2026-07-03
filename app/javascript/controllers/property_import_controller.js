import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "status", "overlay"]

  submitStart(event) {
    if (!this.importSubmission(event)) return

    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.textContent = "Ayla está leyendo..."
      this.buttonTarget.classList.add("opacity-70", "cursor-wait")
    }

    if (this.hasStatusTarget) {
      this.statusTarget.classList.remove("hidden")
      this.statusTarget.textContent = "Ayla está leyendo el archivo. Esto puede tardar unos segundos."
    }

    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.remove("hidden")
    }
  }

  submitEnd(event) {
    if (!this.importSubmission(event)) return

    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false
      this.buttonTarget.textContent = "Leer archivo con IA"
      this.buttonTarget.classList.remove("opacity-70", "cursor-wait")
    }

    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.add("hidden")
    }
  }

  importSubmission(event) {
    const submitter = event.detail?.formSubmission?.submitter || document.activeElement
    return submitter?.name === "preview_import"
  }
}
