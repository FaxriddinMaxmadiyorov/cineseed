import { Controller } from "@hotwired/stimulus"

// One table record: the row opens and closes its details row in place, without a page load.
// Opening also asks the server to start cutting the trailer, so it is usually ready on play.
export default class extends Controller {
  static targets = ["button", "details"]
  static values = { warmUrl: String }

  toggle(event) {
    if (event?.type === "click" && window.getSelection()?.toString()) return // selecting text, not clicking
    const open = this.detailsTarget.hidden
    this.detailsTarget.hidden = !open
    this.buttonTarget.setAttribute("aria-expanded", String(open))
    this.element.classList.toggle("is-open", open)
    if (open) {
      this.warm()
    } else {
      this.detailsTarget.querySelectorAll("video").forEach((video) => video.pause())
    }
  }

  warm() {
    if (this.warmed || !this.warmUrlValue) return
    this.warmed = true
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.warmUrlValue, { method: "POST", headers: token ? { "X-CSRF-Token": token } : {} }).catch(() => {})
  }
}
