import { Controller } from "@hotwired/stimulus"

// Live "N of 50 words" under a paste box, and the submit disabled until it is reachable.
//
// Counts WORDS, not characters, because words are what the probe actually requires: it shows a
// model the opening 30 and compares its continuation against the next 20. A character counter would
// be a friendlier lie, telling someone they were fine at 300 characters of long words and then
// failing them on submit.
//
// The count is the same split Ruby does on the server (`text.split.size` on whitespace), so the two
// never disagree about a paragraph sitting on the boundary.
export default class extends Controller {
  static targets = ["input", "output", "submit", "reason"]
  static values = { min: Number }

  connect() {
    this.update()
  }

  update() {
    const words = this.#count()
    const min = this.minValue
    const short = words < min
    const blocking = short && words > 0

    if (this.hasOutputTarget) {
      this.outputTarget.textContent = words === 0
        ? `${min} words minimum`
        : `${words} of ${min} words`
      this.outputTarget.classList.toggle("wordcount--short", blocking)
      this.outputTarget.classList.toggle("wordcount--ok", !short)
    }

    // Disabled rather than hidden: the button staying visible is what makes the counter legible as
    // the reason. An EMPTY box leaves it enabled, because a paragraph is optional on the main form
    // and the server owns the "you gave us nothing" message.
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = blocking
    }

    if (this.hasReasonTarget) {
      this.reasonTarget.textContent = blocking
        ? `The paragraph needs ${min} words. It has ${words}.`
        : ""
      this.reasonTarget.hidden = !blocking
    }

    // A disabled button whose reason is hidden inside a collapsed <details> is just a broken button.
    // The paste box starts collapsed on the form, so if what is blocking submission is in there,
    // open it: never disable something without showing why in the same glance.
    if (blocking) this.#revealInput()
  }

  #revealInput() {
    if (!this.hasInputTarget) return
    for (let el = this.inputTarget.closest("details"); el; el = el.parentElement?.closest("details")) {
      el.open = true
    }
  }

  #count() {
    if (!this.hasInputTarget) return 0
    return this.inputTarget.value.split(/\s+/).filter(Boolean).length
  }
}
