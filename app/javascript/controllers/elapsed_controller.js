import { Controller } from "@hotwired/stimulus"

// A running clock for a wait that is genuinely long.
//
// The memorization probe takes 60 to 140 seconds because it is 9 to 12 real model calls. For most
// of that the page had one static sentence, which is indistinguishable from a page that has hung.
// A number that moves is the difference between "this is working" and "this is broken", and it is
// worth more than a spinner alone: a spinner says something is happening, elapsed-against-expected
// says whether it is happening on time.
//
// Counts from the run's created_at rather than from page load, so a reload shows the true elapsed
// rather than restarting at zero and implying the wait began again.
export default class extends Controller {
  static targets = ["clock", "bar", "note"]
  static values = {
    startedAt: Number,  // epoch seconds
    expected: Number,   // seconds a healthy run takes
    deadline: Number    // seconds after which the step gives up
  }

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const elapsed = Math.max(0, Math.round(Date.now() / 1000 - this.startedAtValue))

    if (this.hasClockTarget) this.clockTarget.textContent = this.#format(elapsed)

    // The bar fills against the EXPECTED time and then stops, rather than against the deadline.
    // Filling against the deadline would show a bar a third full on a run that is already normal,
    // which reads as slow when it is not.
    if (this.hasBarTarget) {
      const pct = Math.min(100, (elapsed / this.expectedValue) * 100)
      this.barTarget.style.setProperty("--progress", `${pct}%`)
      this.barTarget.classList.toggle("recall__progress--over", elapsed > this.expectedValue)
    }

    // Say so when it runs long, instead of leaving a full bar sitting there implying it is stuck.
    // The deadline is real: the step gives up rather than holding the page open forever.
    if (this.hasNoteTarget && elapsed > this.expectedValue) {
      const left = Math.max(0, this.deadlineValue - elapsed)
      this.noteTarget.textContent = left > 0
        ? `Longer than usual. One slow provider can do this; it gives up after ${this.#format(left)} more.`
        : "Past the deadline. Whatever answered is below; the rest is reported as not asked."
    }
  }

  #format(seconds) {
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return m > 0 ? `${m}m ${String(s).padStart(2, "0")}s` : `${s}s`
  }
}
