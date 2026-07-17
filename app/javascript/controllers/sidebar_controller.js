import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["aside", "content", "header", "label", "link", "toggle", "collapseIcon", "expandIcon"]

  connect() {
    this.collapsed = this.savedPreference()
    this.render()
  }

  toggle() {
    this.collapsed = !this.collapsed
    this.savePreference()
    this.render()
  }

  render() {
    this.asideTarget.classList.toggle("lg:w-72", !this.collapsed)
    this.asideTarget.classList.toggle("lg:px-5", !this.collapsed)
    this.asideTarget.classList.toggle("lg:w-20", this.collapsed)
    this.asideTarget.classList.toggle("lg:px-3", this.collapsed)

    this.contentTarget.classList.toggle("lg:pl-72", !this.collapsed)
    this.contentTarget.classList.toggle("lg:pl-20", this.collapsed)
    this.headerTarget.classList.toggle("lg:flex-col", this.collapsed)

    this.labelTargets.forEach((label) => label.classList.toggle("lg:hidden", this.collapsed))
    this.linkTargets.forEach((link) => link.classList.toggle("lg:justify-center", this.collapsed))

    this.collapseIconTarget.classList.toggle("hidden", this.collapsed)
    this.expandIconTarget.classList.toggle("hidden", !this.collapsed)
    this.toggleTarget.setAttribute("aria-expanded", String(!this.collapsed))
    this.toggleTarget.setAttribute("aria-label", this.collapsed ? "Expandir menú" : "Contraer menú")
    this.toggleTarget.setAttribute("title", this.collapsed ? "Expandir menú" : "Contraer menú")
  }

  savedPreference() {
    try {
      return window.localStorage.getItem("ayla-sidebar-collapsed") === "true"
    } catch {
      return false
    }
  }

  savePreference() {
    try {
      window.localStorage.setItem("ayla-sidebar-collapsed", String(this.collapsed))
    } catch {
      // The menu still works when storage is unavailable.
    }
  }
}
