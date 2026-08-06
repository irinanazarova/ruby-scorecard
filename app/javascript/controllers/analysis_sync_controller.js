import { Controller } from "@hotwired/stimulus"

// Keeps an in-flight analysis converging when the stream cannot.
//
// Two ways the page used to stall with the answer already sitting in the database:
//
//   1. The race. A fully cached run finishes in ~1.5s. The redirect, the render and the WebSocket
//      handshake take longer than that, so every step was broadcast to a page that had not
//      subscribed yet. Nothing errors; the visitor just watches four "waiting" boxes forever. The
//      demo runs on cached examples, so this was the common path, not the rare one.
//   2. A cable that is down. In production the stream is hosted AnyCable and a bad token drops the
//      socket silently.
//
// So the page re-fetches itself while it is not done and swaps in the parts that change. Streaming
// still does the fast, per-step updates; this only catches what the socket missed.
export default class extends Controller {
  static values = { status: String, url: String }

  // Long enough not to hammer the server, short enough that the fallback still feels live. The
  // ceiling covers the memorization deadline (180s) plus the slowest cold Common Crawl lookup.
  static INTERVAL = 2000
  static CEILING_MS = 5 * 60 * 1000

  // These are the regions the job broadcasts. Anything else on the page is static for the run.
  static TARGETS = ["#analysis_verdict", "#analysis_status", ".steps"]

  connect() {
    if (this.statusValue === "done" || this.statusValue === "failed") return

    this.startedAt = Date.now()
    this.timer = setInterval(() => this.poll(), this.constructor.INTERVAL)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    if (Date.now() - this.startedAt > this.constructor.CEILING_MS) return this.stop()

    let doc
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/html" } })
      if (!response.ok) return this.stop()
      doc = new DOMParser().parseFromString(await response.text(), "text/html")
    } catch {
      return // a transient network blip; the next tick tries again
    }

    this.constructor.TARGETS.forEach((selector) => this.sync(doc, selector))

    const fresh = doc.querySelector("[data-analysis-sync-status-value]")
    if (["done", "failed"].includes(fresh?.dataset.analysisSyncStatusValue)) this.stop()
  }

  // Only replaces a region whose markup actually changed, so an open <details> the visitor is
  // reading is not torn out from under them on every tick.
  sync(doc, selector) {
    const next = doc.querySelector(selector)
    const current = this.element.querySelector(selector)
    if (!next || !current || next.innerHTML === current.innerHTML) return

    current.replaceWith(next)
  }

  stop() {
    clearInterval(this.timer)
  }
}
