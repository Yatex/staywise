import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template"]
  static values = {
    nextIndex: Number
  }

  add() {
    const index = this.nextIndexValue
    this.listTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("__INDEX__", index))
    this.nextIndexValue = index + 1
  }
}
