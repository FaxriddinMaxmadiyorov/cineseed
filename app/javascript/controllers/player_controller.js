import { Controller } from "@hotwired/stimulus"

// Freeze frames load when they come into view, a few at a time, so that a page full of them never
// takes every connection to the server while the toolbar or the next page is waiting.
const MAX_LOADING = 3
const waiting = []
let loading = 0

function loadNext() {
  while (loading < MAX_LOADING && waiting.length) {
    const [img, src] = waiting.shift()
    if (!img.isConnected || img.getAttribute("src")) continue
    loading++
    const done = () => {
      loading--
      loadNext()
    }
    img.addEventListener("load", done, { once: true })
    img.addEventListener("error", done, { once: true })
    img.src = src
  }
}

// Freeze frame with a play button; pressing play swaps in the trailer video. The first request for a
// trailer may take a few seconds while the server cuts it, so the player shows a busy state until
// the video can play.
export default class extends Controller {
  static targets = ["poster", "button", "status"]
  static values = { src: String, poster: String, label: String }

  connect() {
    if (this.posterTarget.getAttribute("src")) return
    this.observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      this.observer.disconnect()
      waiting.push([this.posterTarget, this.posterValue])
      loadNext()
    }, { rootMargin: "200px 0px" })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.video?.pause()
  }

  play() {
    if (this.video) {
      this.video.play().catch(() => {})
      return
    }
    const video = document.createElement("video")
    video.className = "player__video"
    video.controls = true
    video.playsInline = true
    video.preload = "auto"
    video.poster = this.posterValue
    video.setAttribute("aria-label", this.labelValue)
    video.addEventListener("playing", () => this.busy(false))
    video.addEventListener("waiting", () => this.busy(true))
    video.addEventListener("play", () => this.pauseOthers(video))
    video.addEventListener("error", () => this.failed())
    video.src = this.srcValue
    this.element.append(video)
    this.element.classList.add("is-started")
    this.video = video
    this.busy(true)
    video.play().catch(() => {}) // autoplay may be refused; the controls stay available
  }

  busy(state) {
    this.element.classList.toggle("is-busy", state)
  }

  failed() {
    this.busy(false)
    this.video?.remove()
    this.video = null
    this.element.classList.remove("is-started")
    this.statusTarget.textContent = this.element.dataset.failedText
  }

  pauseOthers(current) {
    document.querySelectorAll("video").forEach((video) => {
      if (video !== current) video.pause()
    })
  }
}
