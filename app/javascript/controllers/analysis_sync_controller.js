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
  //
  // Every one of them sits INSIDE a slide wrapper rather than being one, which is what keeps this
  // from fighting the deck: swapping a region never touches the wrappers the reveal controller
  // owns, so a broadcast landing mid-walkthrough cannot reset which slides are showing.
  static TARGETS = [
    "#analysis_discoverability",
    "#analysis_funnel",
    "#analysis_recall",
    "#analysis_actions",
    "#analysis_status",
    ".steps"
  ]

  connect() {
    // The scroll guard runs even for a finished analysis, because a Turbo broadcast can still
    // arrive after the page reads as done.
    this.holdScroll = this.holdScroll.bind(this)
    document.addEventListener("turbo:before-stream-render", this.holdScroll)

    if (this.statusValue === "done" || this.statusValue === "failed") return

    this.startedAt = Date.now()
    this.timer = setInterval(() => this.poll(), this.constructor.INTERVAL)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("turbo:before-stream-render", this.holdScroll)
  }

  // Keeps the page still while a region is swapped underneath the reader.
  //
  // The deck fills in as checks land, and a region that grows ABOVE the viewport pushes everything
  // below it down: the page appears to scroll on its own while you are reading. It is not a scroll,
  // it is a reflow, but it is indistinguishable from one and far more annoying, because it happens
  // at a moment the reader did not choose.
  //
  // The only scrolling on this page should be the reveal controller's, on an explicit advance.
  holdScroll() {
    const y = window.scrollY
    // Turbo swaps the element after this event, so the position is restored on the next task once
    // the new markup has been laid out.
    setTimeout(() => {
      if (Math.abs(window.scrollY - y) > 1) window.scrollTo({ top: y, behavior: "auto" })
    }, 0)
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

    // Same reason as holdScroll, on the polling path: replacing a region that changes height moves
    // everything below it. Captured and restored around the swap so the reader stays where they are.
    const y = window.scrollY
    current.replaceWith(next)
    if (Math.abs(window.scrollY - y) > 1) window.scrollTo({ top: y, behavior: "auto" })
  }

  stop() {
    clearInterval(this.timer)
  }
}
