# frozen_string_literal: true

module Analyzer
  # Resolves whatever the user pasted into the two things every later check needs:
  # a documentation URL (for the web channel) and a GitHub repo (for the code channel).
  #
  # Either may be missing, and that absence is itself a finding: a docs page with no public repo
  # has only the web channel, which is the channel that discards most developer documentation.
  class Target
    GITHUB_URL = %r{\Ahttps?://(?:www\.)?github\.com/([^/]+)/([^/#?]+)}i

    # The owner part is [\w-]+ with NO dots, because GitHub usernames and org names cannot contain
    # them. Allowing dots made "example.com/docs" parse as the repo "docs" owned by "example.com",
    # so pasting a bare docs URL silently ran the wrong analysis. Repo NAMES may contain dots
    # (anycable/docs.anycable.io), so only the owner side is restricted.
    REPO_SLUG = %r{\A([\w-]+)/([\w.-]+)\z}

    attr_reader :input, :url, :repo, :kind, :error

    def initialize(input)
      @input = input.to_s.strip
      resolve
    end

    def valid? = @error.nil?

    def to_h = { input:, kind:, url:, repo:, error: }

    private

    def resolve
      return @error = "Enter a documentation URL or a GitHub repo" if @input.empty?

      if (m = @input.match(GITHUB_URL))
        @kind = :repo
        @repo = "#{m[1]}/#{m[2].sub(/\.git\z/, '')}"
        @url  = nil
      elsif (m = @input.match(REPO_SLUG))
        @kind = :repo
        @repo = "#{m[1]}/#{m[2]}"
      elsif @input.match?(%r{\Ahttps?://}i)
        @kind = :url
        @url  = @input
      elsif @input.match?(/\A[\w.-]+\.[a-z]{2,}(\/.*)?\z/i)
        @kind = :url
        @url  = "https://#{@input}"
      else
        @error = "That does not look like a URL or an owner/repo slug"
      end
    end
  end
end
