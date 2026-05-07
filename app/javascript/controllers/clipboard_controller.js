import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    text: String,
    url: String
  }

  async copyText(event) {
    event.preventDefault()
    await navigator.clipboard.writeText(this.textValue || "")
    this.flash(event.currentTarget, "Copied")
  }

  async copyImage(event) {
    event.preventDefault()

    try {
      const response = await fetch(this.urlValue)
      const blob = await response.blob()

      if (window.ClipboardItem) {
        await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })])
        this.flash(event.currentTarget, "Copied")
      } else {
        await navigator.clipboard.writeText(this.textValue || this.urlValue)
        this.flash(event.currentTarget, "Link copied")
      }
    } catch (_error) {
      await navigator.clipboard.writeText(this.textValue || this.urlValue)
      this.flash(event.currentTarget, "Link copied")
    }
  }

  flash(button, message) {
    const original = button.textContent
    button.textContent = message
    window.setTimeout(() => {
      button.textContent = original
    }, 1400)
  }
}
