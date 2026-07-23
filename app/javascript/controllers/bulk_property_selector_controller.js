import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["search", "item", "checkbox", "count", "selectAll", "submit"]

  connect() {
    this.update()
  }

  filter() {
    const query = this.searchTarget.value.trim().toLocaleLowerCase()

    this.itemTargets.forEach((item) => {
      item.hidden = query.length > 0 && !item.dataset.searchText.includes(query)
    })

    this.update()
  }

  toggleVisible() {
    const visibleCheckboxes = this.visibleCheckboxes
    const shouldSelect = visibleCheckboxes.some((checkbox) => !checkbox.checked)

    visibleCheckboxes.forEach((checkbox) => {
      checkbox.checked = shouldSelect
    })

    this.update()
  }

  update() {
    const selectedCount = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    const visibleCheckboxes = this.visibleCheckboxes
    const allVisibleSelected = visibleCheckboxes.length > 0 && visibleCheckboxes.every((checkbox) => checkbox.checked)

    this.countTarget.textContent = selectedCount
    this.selectAllTarget.textContent = allVisibleSelected ? "Deseleccionar visibles" : "Seleccionar visibles"
    this.submitTarget.disabled = selectedCount === 0
    this.submitTarget.classList.toggle("cursor-not-allowed", selectedCount === 0)
    this.submitTarget.classList.toggle("opacity-50", selectedCount === 0)
  }

  get visibleCheckboxes() {
    return this.itemTargets
      .filter((item) => !item.hidden)
      .map((item) => item.querySelector("input[type='checkbox']"))
      .filter(Boolean)
  }
}
