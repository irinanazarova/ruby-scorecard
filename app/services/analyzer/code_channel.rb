# frozen_string_literal: true

module Analyzer
  # "Could this text reach a model through public code rather than the web?"
  #
  # This is the channel that skips the web quality filter entirely, and it is the one most teams
  # ignore. The strongest evidence is OBSERVED: the official "Am I in The Stack?" index says
  # whether code from the repo is in The Stack v3 train set (a direct GitHub crawl, cutoff
  # 2025-08-07, license-filtered per file). The per-file decisions surprise in both directions
  # (karafka/wiki's all-rights-reserved text is in; karafka/karafka's LGPL is out; sidekiq's LGPL
  # is in), so the observed answer always beats inference. When the index cannot be reached, the
  # old inference chain still applies, in the order a corpus builder applies it:
  #
  #   1. Is it public on GitHub at all?
  #   2. Was it COLLECTED? The Stack v2 was built from Software Heritage, where archival is
  #      neither automatic nor star-driven; v3 crawls GitHub directly.
  #   3. Does the LICENSE disqualify it? Only `non_permissive` is dropped. A MISSING license is
  #      fine for The Stack v2/v3 (v1 was stricter), which is the opposite of what most people
  #      assume. The reading also forecasts the NEXT snapshot for repos too new for this one.
  #
  # License classification reads the actual LICENSE text, because GitHub's API reports NOASSERTION
  # for every source-available license: Fizzy, Sentry, Terraform, n8n, Elastic and CockroachDB are
  # indistinguishable from an unlicensed repo in that metadata.
  class CodeChannel
    LICENSE_FILES = %w[LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING MIT-LICENSE
                       MIT-LICENSE.txt LICENSE-MIT LICENSE-APACHE UNLICENSE license license.md].freeze

    # Order matters. The O'Saasy license quotes the MIT grant verbatim before adding restrictions,
    # so a "does it contain the MIT words" test calls it permissive, the opposite of its intent.
    # NOTE: do not add the /x flag here. It strips literal spaces from the pattern, which silently
    # breaks every multi-word alternative ("permission is hereby granted" stops matching) and sends
    # ordinary MIT repos to :unknown. Single-line /i patterns only.
    PATTERNS = [
      [:source_available, /o'?saasy|functional source license|FSL-1\.1|business source license|\bBUSL\b|server side public license|\bSSPL\b|elastic license|sustainable use license|commons clause|fair source|polyform/i],
      [:proprietary,      /all rights reserved(?!.{0,400}(permission is hereby granted|redistribution))/im],
      [:copyleft,         /gnu affero|affero general public|gnu general public license|lesser general public|mozilla public license|\bAGPL\b|\bGPL\b|\bLGPL\b/i],
      [:content,          /creative commons|\bCC[- ]BY\b|attribution-sharealike/i],
      [:permissive,       /permission is hereby granted, free of charge|apache license|redistribution and use in source and binary forms|\bISC License\b|this is free and unencumbered software/i]
    ].freeze

    RATE_LIMIT_REASON = "GitHub rate limit reached for this server, so the code channel could not " \
                        "be checked. This says nothing about the repo. Unauthenticated GitHub " \
                        "allows 60 requests/hour per IP; a token raises it to 5,000."

    STACK_SPACE  = "https://huggingfacecode-in-the-stack.hf.space"
    STACK_CUTOFF = "2025-08-07"

    KEPT_BY_STACK = { permissive: true, no_license: true, content: :depends,
                      copyleft: false, source_available: false, proprietary: false,
                      unknown: :unknown }.freeze

    LABELS = { "O'Saasy" => /o'?saasy/i, "FSL-1.1" => /functional source license|FSL-1\.1/i,
               "BUSL-1.1" => /business source license|BUSL/i, "SSPL" => /server side public/i,
               "Elastic License" => /elastic license/i, "Sustainable Use" => /sustainable use/i,
               "Commons Clause" => /commons clause/i, "PolyForm" => /polyform/i }.freeze

    def initialize(repo) = @repo = repo

    def call
      return { present: false, reason: "No public GitHub repo found for this page" } unless @repo

      res = Http.probe("https://api.github.com/repos/#{@repo}", headers: gh_headers, timeout: 20)
      info = parse(res)
      unless info && info["full_name"]
        # 404 is a fact about the repo and caches fine. A rate limit or a network error is a fact
        # about this server, so it must expire immediately rather than persist for the cache TTL.
        return { present: false, reason: failure_reason(res), transient: res[:status] != 404 }
      end

      branch = info["default_branch"]
      file, text = license_text(branch)
      klass = classify(text)
      swh = archived_in_swh?
      in_v3 = in_stack_v3?(info["full_name"])
      created = info["created_at"].to_s[0, 10]
      post_cutoff = in_v3 == false && created > STACK_CUTOFF

      checks = [
        { name: "Public on GitHub", pass: true, detail: "#{info['full_name']} (#{info['stargazers_count']} stars)",
          why: "Public code is the channel that skips the web quality filter." }
      ]
      # A red X reading "index unreachable" would blame the repo for our network, so the observed
      # check only appears when the index actually answered; consumers fall back to inference.
      unless in_v3.nil?
        checks << { name: "In The Stack v3 (observed)", pass: in_v3,
                    detail: stack_detail(in_v3, post_cutoff),
                    why: "The Stack v3 is a direct GitHub crawl (cutoff #{STACK_CUTOFF}), " \
                         "license-filtered per file. Membership is read from the official " \
                         "Am-I-in-The-Stack index: the corpus's own answer, not a license guess." }
      end
      checks << { name: "Collected by Software Heritage", pass: swh,
                  detail: swh ? "archived" : "not archived",
                  why: "The Stack v2 was built from the SWH archive (v3 crawls GitHub directly), " \
                       "so archival is durable collection evidence for SWH-based corpora." }
      checks << { name: "License permits inclusion", pass: KEPT_BY_STACK[klass] == true,
                  detail: license_detail(klass, file, text),
                  why: "Corpora drop non_permissive files by name; the reading also decides the " \
                       "next snapshot for repos this one missed. A missing license is NOT a " \
                       "disqualifier for The Stack v2/v3." }

      {
        present: true, repo: info["full_name"], stars: info["stargazers_count"],
        forks: info["forks_count"], created: created,
        github_spdx: info.dig("license", "spdx_id") || "NONE",
        license_file: file, license_class: klass, license_label: label(text),
        github_mislabels: mislabels?(info, klass),
        swh_archived: swh,
        in_stack_v3: in_v3, stack_cutoff: STACK_CUTOFF, post_cutoff: post_cutoff,
        kept_by_stack: KEPT_BY_STACK[klass],
        checks: checks
      }
    end

    private

    def gh_headers = Http.github_headers

    def parse(res)
      return nil unless res[:ok]

      JSON.parse(res[:body].to_s)
    rescue JSON::ParserError
      nil
    end

    # Every non-success used to print "Repo not found or private", including the one that actually
    # happens in production: the 60 requests/hour unauthenticated limit is PER IP, and one Fly
    # machine shares its egress IP with every visitor, so it is exhausted by a handful of analyses.
    # Reporting a public repo as missing is the most misleading thing this page could say, because
    # the code channel is the one the whole argument rests on.
    def failure_reason(res)
      case res[:status]
      when 403, 429
        rate_limited?(res) ? RATE_LIMIT_REASON : "GitHub refused the request for #{@repo} (403)."
      when 404 then "Repo not found or private: #{@repo}"
      when nil then "Could not reach GitHub. This is a network problem here, not a fact about #{@repo}."
      else "GitHub returned #{res[:status]} for #{@repo}."
      end
    end

    def rate_limited?(res) = res[:body].to_s.include?("rate limit")

    def license_text(branch)
      LICENSE_FILES.each do |f|
        r = Http.probe("https://raw.githubusercontent.com/#{@repo}/#{branch}/#{f}", timeout: 8)
        return [f, r[:body]] if r[:ok] && r[:body].to_s.strip.length > 40
      end
      [nil, nil]
    end

    def classify(text)
      return :no_license if text.nil?

      head = text[0, 8000]
      PATTERNS.each { |cls, pat| return cls if head.match?(pat) }
      :unknown
    end

    def label(text)
      return nil unless text

      LABELS.each { |name, pat| return name if text[0, 3000].match?(pat) }
      nil
    end

    # The headline finding for source-available products: GitHub says "Other", so dashboards and
    # tooling that trust spdx_id treat Fizzy and an unlicensed weekend project identically.
    def mislabels?(info, klass)
      spdx = info.dig("license", "spdx_id")
      (spdx.nil? || spdx == "NOASSERTION") && %i[source_available copyleft proprietary].include?(klass)
    end

    def license_detail(klass, file, text)
      name = label(text) || klass.to_s.tr("_", " ")
      case klass
      when :permissive       then "#{name} (#{file}) - kept"
      when :no_license       then "no LICENSE file - still kept by The Stack v2/v3"
      when :source_available then "#{name} (#{file}) - source-available, excluded as non-permissive"
      when :copyleft         then "copyleft (#{file}) - excluded as non-permissive"
      when :proprietary      then "all rights reserved (#{file}) - excluded"
      when :content          then "content license (#{file}) - depends on the share-alike terms"
      else "could not classify #{file}"
      end
    end

    def archived_in_swh?
      d = Http.json("https://archive.softwareheritage.org/api/1/origin/https://github.com/#{@repo}/visit/latest/",
                    timeout: 15)
      d.is_a?(Hash) && d["status"] == "full"
    end

    # Observed membership in The Stack v3 train set, via the official "Am I in The Stack?" space
    # (a Gradio app: POST the owner, then fetch the result by event id; the reply is Markdown
    # listing every repo of that owner in the set). Returns true/false, or nil when the index
    # could not be consulted; nil is a fact about this server or the space, never about the repo.
    def in_stack_v3?(full_name)
      owner = full_name.split("/").first.downcase
      post = Http.post_json("#{STACK_SPACE}/gradio_api/call/check_username",
                            { data: [owner] }, timeout: 30)
      event = post && post["event_id"]
      return nil unless event

      res = Http.get("#{STACK_SPACE}/gradio_api/call/check_username/#{event}", timeout: 90)
      return nil unless res.is_a?(Net::HTTPSuccess)

      line = Http.utf8(res.body).to_s.lines.find { |l| l.start_with?("data:") }
      return nil unless line

      payload = begin
        JSON.parse(line.sub(/\Adata:\s*/, ""))
      rescue JSON::ParserError
        nil
      end
      return nil unless payload.is_a?(Array) && payload.first.is_a?(String)

      payload.first.scan(%r{github\.com/([\w.-]+/[\w.-]+)\)}).flatten
             .map(&:downcase).include?(full_name.downcase)
    end

    def stack_detail(in_v3, post_cutoff)
      return "in the v3 train set" if in_v3
      return "not in v3: the repo is newer than the #{STACK_CUTOFF} crawl cutoff" if post_cutoff

      "not in the v3 train set"
    end
  end
end
