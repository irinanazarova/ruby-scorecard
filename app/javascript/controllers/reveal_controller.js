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

  next() {
    if (this.revealedValue >= this.stageTargets.length) return

    this.revealedValue += 1
    this.scrollTo(this.stageTargets[this.revealedValue - 1])
  }

  back() {
    if (this.revealedValue <= 1) return

    this.revealedValue -= 1
    this.scrollTo(this.stageTargets[this.revealedValue - 1])
  }

  all() {
    this.revealedValue = this.stageTargets.length
  }

  handleKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    const tag = document.activeElement?.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return

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

  // render() has already removed the hidden class by the time this runs, and reading the element's
  // box forces the layout that makes the new position real, so the scroll needs no deferral.
  //
  // It used to sit inside requestAnimationFrame, which does not fire while a tab is in the
  // background: reveal one slide, switch tabs, come back, and the deck had advanced without ever
  // moving.
  scrollTo(stage) {
    if (!stage) return

    stage.getBoundingClientRect()
    stage.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}
