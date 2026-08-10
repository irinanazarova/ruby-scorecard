# frozen_string_literal: true

# The three inputs on /test, validated as a unit.
#
# WHY A FORM OBJECT. Validation used to be a single `error` string on Analyzer::Target, and a
# failure meant `redirect_to test_path, alert: ...`. That is the Rails anti-pattern this class
# exists to remove: a redirect discards the request, so someone who pasted six paragraphs and got
# one field wrong lost all of it and was handed a flash at the top of an empty form. An error also
# has to know WHICH field it belongs to before it can be rendered next to that field, and a bare
# string does not.
#
# So: ActiveModel, errors attached to attributes, and the controller re-renders with
# :unprocessable_entity. That status is not decoration. Turbo Drive only replaces the page from a
# form submission when the response is non-2xx; return 200 and it discards the body, leaving the
# visitor looking at an unchanged form with no errors on it.
#
# Presentation layer: this shapes and checks what arrived from a form. Analyzer::Target stays the
# domain object that later checks are built from, and this hands one over once it is satisfied.
class AnalysisForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :docs_url, :string
  attribute :repo, :string
  attribute :passage, :string

  validate :something_given
  validate :docs_url_parses
  validate :repo_parses
  validate :passage_long_enough

  # The domain object the rest of the run is built from. Only meaningful once valid?.
  def target
    @target ||= Analyzer::Target.new(docs_url: docs_url, repo: repo, passage: passage)
  end

  # Words in the pasted paragraph, counted the way the probe counts them, so the hint under the box
  # and the validation below can never disagree.
  def passage_words = passage.to_s.split.size

  def self.minimum_words = Analyzer::Passage::MIN_PASTED_WORDS

  private

  # Attached to :base rather than to a field: the rule is about the trio, and picking one of the
  # three to blame would put the message under a box that is not the problem.
  def something_given
    return if [ docs_url, repo, passage ].any?(&:present?)

    errors.add(:base, "Enter your documentation site, your repo, or a paragraph to check")
  end

  # Parsing lives in Target, which owns the rules (bare hosts get https://, a github.com link in the
  # docs box is a misfiled repo). This only decides which FIELD an objection belongs to, by asking
  # Target about that field alone.
  def docs_url_parses
    return if docs_url.blank?

    t = Analyzer::Target.new(docs_url: docs_url)
    errors.add(:docs_url, t.error) unless t.valid?
  end

  def repo_parses
    return if repo.blank?

    t = Analyzer::Target.new(repo: repo)
    errors.add(:repo, t.error) unless t.valid?
  end

  # The probe shows a model the opening words and compares what it writes next against the rest, so
  # a paragraph has to be long enough to split in two. Below the floor there is nothing to compare
  # against and the answer would always be "no recall", which is worse than refusing.
  def passage_long_enough
    return if passage.blank?
    return if passage_words >= self.class.minimum_words

    # Written to stand on its own, because it renders under the labelled box rather than through
    # full_messages. ActiveModel's convention assumes a "Passage " prefix that is not there, and
    # without it the default phrasing reads as the fragment "is 3 words."
    errors.add(:passage, "That paragraph is #{passage_words} words. The probe needs at least " \
                         "#{self.class.minimum_words}, because it shows a model the opening " \
                         "#{Analyzer::Passage::MIN_SEED} and compares what it writes next against the rest.")
  end
end
