import { Controller } from "@hotwired/stimulus"

// The toolbar submits itself whenever a parameter changes: no Enter key, no apply button.
// Typing waits for a short pause; selects, the view switch and finished slider moves apply at once.
// Submitting never sends a page number, so every change starts again from page 1 (table) or from the
// first batch at the top (gallery).
export default class extends Controller {
  static targets = ["seed"]

  connect() {
    this.lastQuery = this.query()
    this.frame = document.getElementById("catalog")
    this.frameLoaded = this.frameLoaded.bind(this)
    this.frame?.addEventListener("turbo:before-frame-render", this.frameLoaded)
    // a fresh visit starts from a random seed chosen by the server: show it in the address bar too
    const url = new URL(window.location.href)
    if (!url.searchParams.has("seed")) {
      window.history.replaceState(window.history.state, "", `${url.pathname}?${this.lastQuery}`)
    }
  }

  disconnect() {
    clearTimeout(this.timer)
    this.frame?.removeEventListener("turbo:before-frame-render", this.frameLoaded)
  }

  changed(event) {
    const field = event.target
    if (field.dataset.sync) this.sync(field)
    clearTimeout(this.timer)
    const typing = event.type === "input" && (field.type === "text" || field.type === "number" || field.type === "range")
    if (typing) {
      this.timer = setTimeout(() => this.apply(), field.type === "range" ? 180 : 380)
    } else {
      if (event.type === "change" && field.type === "number") this.clamp(field)
      this.apply()
    }
  }

  randomSeed() {
    const words = crypto.getRandomValues(new Uint32Array(2))
    const seed = (BigInt(words[0] & 0x1fffff) << 32n) | BigInt(words[1]) // 53 bits
    this.seedTarget.value = seed.toString()
    this.apply()
  }

  // Enter in a field submits through Turbo like any other change.
  submitted(event) {
    if (this.query() === this.lastQuery) event.preventDefault()
    this.lastQuery = this.query()
  }

  apply() {
    if (this.query() === this.lastQuery) return
    this.element.requestSubmit()
  }

  query() {
    return new URLSearchParams(new FormData(this.element)).toString()
  }

  // The slider and the number box of one average always show the same value.
  sync(field) {
    this.element.querySelectorAll(`[data-sync="${field.dataset.sync}"]`).forEach((other) => {
      if (other !== field) other.value = field.value
    })
  }

  clamp(field) {
    const value = Number.parseFloat(field.value.replace(",", "."))
    field.value = Number.isFinite(value) ? String(Math.min(10, Math.max(0, Math.round(value * 100) / 100))) : "0"
    this.sync(field)
  }

  // New parameters or another table page: start reading from the top. Scrolling before the new content
  // is drawn keeps the next gallery batch out of view, so it is not fetched needlessly. Gallery
  // batches render inside nested frames whose events bubble here too; those must not move the page.
  frameLoaded(event) {
    if (event.target !== this.frame) return
    window.scrollTo({ top: 0, behavior: "instant" })
  }
}
