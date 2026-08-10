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
  static targets = ["input", "output", "submit"]
  static values = { min: Number }

  connect() {
    this.update()
  }

  update() {
    const words = this.#count()
    const min = this.minValue
    const short = words < min

    if (this.hasOutputTarget) {
      this.outputTarget.textContent = words === 0
        ? `${min} words minimum`
        : `${words} of ${min} words`
      this.outputTarget.classList.toggle("wordcount--short", short && words > 0)
      this.outputTarget.classList.toggle("wordcount--ok", !short)
    }

    // Disabled rather than hidden: the button staying visible is what makes the counter legible as
    // the reason. An empty box leaves it enabled so the server still owns the "you gave us nothing"
    // message, which is the one case where a paragraph is not required at all.
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = short && words > 0
    }
  }

  #count() {
    if (!this.hasInputTarget) return 0
    return this.inputTarget.value.split(/\s+/).filter(Boolean).length
  }
}
