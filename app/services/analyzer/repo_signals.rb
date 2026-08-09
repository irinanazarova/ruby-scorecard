# frozen_string_literal: true

module Analyzer
  # "Can an agent discover your repo, evaluate it, and suggest it to someone?"
  #
  # This is the repo half of agent experience, and it is a different question from the one
  # CodeChannel answers. CodeChannel asks whether a corpus builder would KEEP these files months
  # from now. This asks whether an agent working right now, with a browser and the GitHub API, can
  # find the project, tell what it does, and have enough grounds to recommend it.
  #
  # Scope stops at "suggest" on purpose. Whether the agent can then install it, configure it, deploy
  # it or pay for it is a separate and much larger question, and nothing here measures it.
  #
  # Every check is a fact read from the GitHub API, so there is no scoring or judgement in this
  # class. A rate limit is reported as a rate limit rather than as a missing repo: saying a public
  # project does not exist is the most damaging thing this page could get wrong.
  class RepoSignals
    # Below this a README is a title and a badge row. An agent reading it cannot say what the
    # project does, which is the thing it needs before it can suggest anything.
    MIN_README_WORDS = 80

    # Repos go quiet for good reasons, and a year is long enough that neither a slow release cycle
    # nor a holiday reads as abandonment.
    STALE_AFTER = 12

    def initialize(repo) = @repo = repo

    def call
      return { present: false, reason: "No repo given" } unless @repo

      res = Http.probe("https://api.github.com/repos/#{@repo}", headers: Http.github_headers, timeout: 20)
      info = parse(res)
      unless info && info["full_name"]
        return { present: false, reason: failure_reason(res), transient: res[:status] != 404 }
      end

      readme = readme_words
      topics = Array(info["topics"])
      months = months_since(info["pushed_at"])

      {
        present: true, repo: info["full_name"], stars: info["stargazers_count"],
        description: info["description"], topics: topics, readme_words: readme,
        months_since_push: months, releases: release_count,
        checks: [
          check("Public on GitHub", true,
                detail: "#{info['full_name']}, #{info['stargazers_count']} stars",
                why: "A private repo is invisible to every agent and every corpus."),

          check("README explains the project", readme.to_i >= MIN_README_WORDS,
                detail: readme.nil? ? "no README found" : "#{readme} words of prose",
                why: "The README is what an agent reads first and quotes when it recommends you."),

          check("Description and topics set", info["description"].present? && topics.any?,
                detail: topic_detail(info["description"], topics),
                why: "Description and topics are the fields GitHub search matches on."),

          check("Tagged releases", release_count.to_i.positive?,
                detail: release_count.to_i.positive? ? "#{release_count} published releases" : "no published releases",
                why: "Releases give an agent a version to name instead of guessing at main."),

          check("Active in the last #{STALE_AFTER} months", months && months <= STALE_AFTER,
                detail: months ? "last push #{months_label(months)}" : "no push date",
                why: "Agents weigh recency when deciding what to recommend, and so do the people reading the answer.")
        ]
      }
    end

    private

    def check(name, pass, detail:, why:) = { name:, pass:, detail:, why: }

    def parse(res)
      return nil unless res[:ok]

      JSON.parse(res[:body].to_s)
    rescue JSON::ParserError
      nil
    end

    # Shares CodeChannel's wording, and for the same reason: the unauthenticated GitHub limit is 60
    # requests/hour PER IP, and one Fly machine shares its egress IP with every visitor.
    def failure_reason(res)
      case res[:status]
      when 403, 429 then CodeChannel::RATE_LIMIT_REASON
      when 404 then "Repo not found or private: #{@repo}"
      when nil then "Could not reach GitHub. This is a network problem here, not a fact about #{@repo}."
      else "GitHub returned #{res[:status]} for #{@repo}."
      end
    end

    # The rendered README, measured as words of prose rather than bytes: a wall of badges and a
    # table of contents is a large file that tells an agent nothing.
    def readme_words
      return @readme_words if defined?(@readme_words)

      res = Http.probe("https://api.github.com/repos/#{@repo}/readme",
                       headers: Http.github_headers.merge("Accept" => "application/vnd.github.raw"),
                       timeout: 15)
      @readme_words = res[:ok] ? Passage.strip_markdown(res[:body]).split.length : nil
    end

    def release_count
      return @release_count if defined?(@release_count)

      res = Http.probe("https://api.github.com/repos/#{@repo}/releases?per_page=5",
                       headers: Http.github_headers, timeout: 15)
      @release_count = res[:ok] ? (JSON.parse(res[:body].to_s).length rescue nil) : nil
    end

    def topic_detail(description, topics)
      return "description and #{topics.size} topics" if description.present? && topics.any?
      return "description set, no topics" if description.present?
      return "topics set, no description" if topics.any?

      "neither set"
    end

    def months_since(timestamp)
      t = Time.zone.parse(timestamp.to_s) or return nil
      ((Time.current - t) / 1.month).floor
    rescue StandardError
      nil
    end

    def months_label(months)
      return "this month" if months.zero?

      "#{months} #{'month'.pluralize(months)} ago"
    end
  end
end
