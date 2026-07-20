import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["messages"]
  static values = {
    interval: { type: Number, default: 5000 },
    url: String,
  }

  connect() {
    this.refreshing = false
    this.abortController = null
    requestAnimationFrame(() => this.scrollToLatestMessage())
    this.stopPolling()
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    this.stopPolling()
    this.abortController?.abort()
  }

  async refresh() {
    if (document.hidden) return
    if (this.refreshing) return
    const afterMessageId = this.messagesTarget?.dataset.lastMessageId
    if (!afterMessageId) return

    this.refreshing = true
    this.abortController = new AbortController()

    try {
      const url = new URL(this.urlValue || window.location.href, window.location.origin)
      url.searchParams.set("after_message_id", afterMessageId)
      const response = await fetch(url, {
        headers: { Accept: "text/html" },
        signal: this.abortController.signal,
      })
      if (response.status === 204) return
      if (!response.ok) return

      const html = await response.text()
      const documentFragment = new DOMParser().parseFromString(html, "text/html")
      const wasNearBottom = this.nearPageBottom()
      const messagesChanged = this.appendNewMessages(documentFragment)

      if (messagesChanged && wasNearBottom) {
        this.scrollToLatestMessage()
      }
    } catch (error) {
      if (error.name !== "AbortError") throw error
    } finally {
      this.refreshing = false
      this.abortController = null
    }
  }

  appendNewMessages(documentFragment) {
    const list = this.messagesTarget?.querySelector("#conversation-messages-list")
    if (!list) return false

    let changed = false
    documentFragment.querySelectorAll("[data-message-id]").forEach((message) => {
      if (document.getElementById(message.id)) return

      list.appendChild(message)
      this.messagesTarget.dataset.lastMessageId = message.dataset.messageId
      changed = true
    })
    return changed
  }

  stopPolling() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  nearPageBottom() {
    return window.innerHeight + window.scrollY >= document.body.offsetHeight - 240
  }

  scrollToLatestMessage() {
    const latestMessage = this.messagesTarget?.querySelector("[id^='message-']:last-child")
    if (latestMessage) {
      latestMessage.scrollIntoView({ block: "end" })
    }
  }
}
