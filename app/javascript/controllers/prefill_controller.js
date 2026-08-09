import { Controller } from "@hotwired/stimulus"

// Drops a listed example into the two form fields instead of running it.
//
// On stage the point of the pair is that you can SEE both halves before anything happens: the tool
// no longer works the repo out for you, and the fastest way to make that land is to fill the boxes
// in front of the room and then press Analyze.
export default class extends Controller {
  static targets = ["docs", "repo"]

  fill(event) {
    const { docs, repo } = event.currentTarget.dataset
    if (this.hasDocsTarget) this.docsTarget.value = docs || ""
    if (this.hasRepoTarget) this.repoTarget.value = repo || ""

    this.element.scrollIntoView({ behavior: "smooth", block: "start" })
    if (this.hasDocsTarget) this.docsTarget.focus({ preventScroll: true })
  }
}
