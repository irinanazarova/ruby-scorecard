# frozen_string_literal: true

module Analyzer
  # The two things every later check needs: a documentation URL for the web channel, and a GitHub
  # repo for the code channel.
  #
  # Both are asked for directly. The previous version took a single box and INFERRED the missing
  # half, walking from "a repo named after this site" down to "the org's most-starred repo", and
  # that last step is a guess. A guess is a bad foundation for a licence verdict, because the answer
  # it produces is indistinguishable on screen from a measured one: docs.anycable.io resolved to
  # anycable/anycable, a different repo with a different history, and the page then reported that
  # repo's licence as though it covered the docs.
  #
  # So nothing is inferred here. Either field may be left empty, and which one is empty is part of
  # the result: docs with no repo has only the web channel, which is the channel that discards most
  # developer documentation.
  class Target
    # The scheme is optional because a browser address bar hides it, so the thing people actually
    # paste is `github.com/owner/repo`. Requiring https:// rejected that with "not an owner/repo slug
    # or a github.com link", which is a confusing thing to be told about a github.com link.
    GITHUB_URL = %r{\A(?:https?://)?(?:www\.)?github\.com/([^/]+)/([^/#?]+)}i

    # The owner part is [\w-]+ with NO dots, because GitHub usernames and org names cannot contain
    # them. Allowing dots made "example.com/docs" parse as the repo "docs" owned by "example.com".
    # Repo NAMES may contain dots (anycable/docs.anycable.io), so only the owner side is restricted.
    REPO_SLUG = %r{\A([\w-]+)/([\w.-]+)\z}

    BARE_HOST = %r{\A[\w.-]+\.[a-z]{2,}(/.*)?\z}i

    attr_reader :url, :repo, :passage, :error, :docs_input, :repo_input

    def initialize(docs_url: nil, repo: nil, passage: nil)
      @docs_input = docs_url.to_s.strip
      @repo_input = repo.to_s.strip
      @passage = passage.to_s.strip.presence
      resolve
    end

    # One box, split. Kept for the rake tasks and for re-running rows created before the form had
    # two fields, so an old permalink still resolves to something meaningful.
    def self.from_input(input)
      text = input.to_s.strip
      if text.match?(GITHUB_URL) || text.match?(REPO_SLUG)
        new(repo: text)
      else
        new(docs_url: text)
      end
    end

    def valid? = @error.nil?

    def docs? = url.present?
    def repo? = repo.present?
    def passage? = passage.present?

    # A run with nothing but a pasted paragraph answers ONE question, and half the page does not
    # apply to it: there is no URL to fetch and no repo to read. The deck asks this to decide which
    # slides to show rather than rendering two slides of "nothing given to check".
    def passage_only? = passage? && !docs? && !repo?

    def kind
      return :passage if passage_only?
      return :both if docs? && repo?

      docs? ? :url : :repo
    end

    # What the run is called on screen and in the database. Every part, because a result page titled
    # with only one of them hides which repo the licence verdict came from.
    def label
      parts = [ url, repo ].compact_blank
      parts << "a #{passage.split.size}-word paragraph" if passage?
      parts.join("  +  ")
    end

    def to_h
      { docs_url: url, repo: repo, passage: passage, kind: kind, label: label, error: error }
    end

    # The key every per-check cache entry hangs off. Every part, because the memorization probe now
    # covers all of them and a run with a repo attached is not the same measurement as one without.
    # The paragraph is digested rather than included: it can be arbitrarily long, and a cache key
    # carrying someone's text in the clear is a worse idea than a hash of it.
    def cache_key = "#{url}|#{repo}|#{passage && Digest::SHA256.hexdigest(passage)[0, 16]}"

    private

    def resolve
      if @docs_input.blank? && @repo_input.blank? && @passage.blank?
        return @error = "Enter your documentation site, your repo, or a paragraph to check"
      end

      resolve_docs
      resolve_repo unless @error
      resolve_passage unless @error
    end

    # The probe shows a model the opening words and compares what it writes next against the rest,
    # so a paragraph has to be long enough to be split in two. Below the floor there is nothing to
    # compare against and the answer would always be "no recall", which is worse than refusing.
    def resolve_passage
      return if @passage.blank?

      words = @passage.split.size
      return if words >= Passage::MIN_PASTED_WORDS

      @error = "That paragraph is #{words} words. The probe shows a model the opening words and " \
               "compares what it writes next against the rest, so it needs at least " \
               "#{Passage::MIN_PASTED_WORDS}."
    end

    def resolve_docs
      return if @docs_input.blank?

      # A GitHub URL in the docs box is a misfiled repo rather than a documentation site, and
      # silently running it as a web target would report "not in Common Crawl" about a page that was
      # never a page.
      if (m = @docs_input.match(GITHUB_URL))
        @repo_input = "#{m[1]}/#{m[2].sub(/\.git\z/, '')}" if @repo_input.blank?
        return
      end

      if @docs_input.match?(%r{\Ahttps?://}i)
        @url = @docs_input
      elsif @docs_input.match?(BARE_HOST)
        @url = "https://#{@docs_input}"
      else
        @error = "\"#{@docs_input}\" does not look like a documentation URL"
      end
    end

    def resolve_repo
      return if @repo_input.blank?

      if (m = @repo_input.match(GITHUB_URL))
        @repo = "#{m[1]}/#{m[2].sub(/\.git\z/, '')}"
      elsif (m = @repo_input.match(REPO_SLUG))
        @repo = "#{m[1]}/#{m[2]}"
      else
        @error = "\"#{@repo_input}\" is not an owner/repo slug or a github.com link"
      end
    end
  end
end
