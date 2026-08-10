import { Controller } from "@hotwired/stimulus"

// Walks the results one slide at a time, like a deck.
//
// Slides ACCUMULATE rather than replace each other: pressing forward reveals the next one and
// scrolls to it, and everything already shown stays on the page. A results page that swapped slides
// would be worse than what it replaced, because the thing a visitor does after the walk-through is
// scroll back over the whole argument.
//
// Reveal state lives here and not in the markup, which matters because the slides are refilled by
// Turbo Stream broadcasts while a run is still going: only the inner regions get replaced, so the
// stage wrappers this controller owns survive every update.
export default class extends Controller {
  static targets = ["stage", "hint", "dot", "back", "forward", "all"]
  static values = { revealed: Number }

  connect() {
    if (!this.revealedValue || this.revealedValue < 1) this.revealedValue = 1
    this.handleKey = this.handleKey.bind(this)
    window.addEventListener("keydown", this.handleKey)
    this.render()
  }

  disconnect() {
    window.removeEventListener("keydown", this.handleKey)
  }

  revealedValueChanged() {
    this.render()
  }

  // Clicking the page advances, which is what makes this feel like a presentation. Anything the
  // visitor might actually want to click keeps its own behaviour: without this guard, following a
  // "Why" link into /learn also skipped a slide on the way out.
  advance(event) {
    if (event.target.closest("a, button, input, textarea, select, summary, details, [data-no-advance]")) return
    this.next()
  }

  // render() is called explicitly before scrolling, and that is the whole trick.
  //
  // Assigning to a Stimulus value writes a data attribute, and revealedValueChanged fires from the
  // MutationObserver that watches it — on a microtask, AFTER this method finishes. So the scroll ran
  // while the slide it was scrolling to was still display:none, and scrolling to a hidden element
  // does nothing at all. The reveal worked, the page just never moved.
  //
  // Calling render() here un-hides the slide first. The second call from the value callback is
  // idempotent and costs nothing.
  next() {
    if (this.revealedValue >= this.stageTargets.length) return

    this.revealedValue += 1
    this.render()
    this.scrollTo(this.stageTargets[this.revealedValue - 1])
  }

  back() {
    if (this.revealedValue <= 1) return

    this.revealedValue -= 1
    this.render()
    this.scrollTo(this.stageTargets[this.revealedValue - 1])
  }

  all() {
    this.revealedValue = this.stageTargets.length
  }

  handleKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    const tag = document.activeElement?.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return

    // Enter and Space on a focused button already fire a click, which advances on its own. Without
    // this, pressing Enter right after clicking Next skipped two slides at once.
    const onButton = document.activeElement?.tagName === "BUTTON"
    if (onButton && ["Enter", " "].includes(event.key)) return

    if (["ArrowRight", "PageDown", "Enter", " "].includes(event.key)) {
      event.preventDefault()
      this.next()
    } else if (["ArrowLeft", "PageUp"].includes(event.key)) {
      event.preventDefault()
      this.back()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.all()
    }
  }

  render() {
    const total = this.stageTargets.length
    const shown = Math.min(this.revealedValue, total)

    this.stageTargets.forEach((stage, i) => {
      const visible = i < shown
      stage.classList.toggle("stage--hidden", !visible)
      stage.setAttribute("aria-hidden", visible ? "false" : "true")
      // Hidden slides must be out of the tab order too, or Tab walks into content nobody can see.
      stage.querySelectorAll("a, button, input, summary").forEach((el) => {
        if (visible) el.removeAttribute("tabindex")
        else el.setAttribute("tabindex", "-1")
      })
    })

    this.dotTargets.forEach((dot, i) => dot.classList.toggle("dot--on", i < shown))

    const done = shown >= total
    if (this.hasHintTarget) this.hintTarget.classList.toggle("is-spent", done)
    if (this.hasForwardTarget) this.forwardTarget.disabled = done
    if (this.hasBackTarget) this.backTarget.disabled = shown <= 1
    if (this.hasAllTarget) this.allTarget.hidden = done
  }

  // Getting the page to actually move took three goes, so the reasons are worth keeping:
  //
  //   1. It sat inside requestAnimationFrame, which does not fire in a background tab: reveal a
  //      slide, switch away, come back, and the deck had advanced without ever scrolling.
  //   2. Without that accidental delay, the scroll ran BEFORE Stimulus's mutation observer had
  //      called render(), so it was scrolling to an element that was still display:none. Callers
  //      now render() first.
  //   3. `behavior: "smooth"` is silently dropped in some browsers and settings: measured here,
  //      an instant scroll moved to 1642 and the identical smooth scroll moved nothing at all.
  //
  // So the smooth scroll is attempted and then CHECKED, and if the page has not moved it is set
  // outright. An animation is a nicety; arriving at the slide is the feature.
  scrollTo(stage) {
    if (!stage) return

    const from = window.scrollY
    // scroll-margin-top on .stage does not apply to a computed window scroll, so leave the gap here.
    const top = Math.max(0, from + stage.getBoundingClientRect().top - 16)

    window.scrollTo({ top, behavior: "smooth" })
    setTimeout(() => {
      if (Math.abs(window.scrollY - from) < 4) window.scrollTo({ top, behavior: "auto" })
    }, 250)
  }
}
