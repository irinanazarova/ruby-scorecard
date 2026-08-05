# frozen_string_literal: true

module Analyzer
  # "Could this text reach a model through public code rather than the web?"
  #
  # This is the channel that skips the web quality filter entirely, and it is the one most teams
  # ignore. Three gates, in the order a corpus builder applies them:
  #
  #   1. Is it public on GitHub at all?
  #   2. Was it COLLECTED? The Stack v2/v3 are built from Software Heritage, and archival there is
  #      neither automatic nor star-driven. A permissive license on an uncollected repo buys nothing.
  #   3. Does the LICENSE disqualify it? Only `non_permissive` is dropped. A MISSING license is fine
  #      for The Stack v2/v3 (v1 was stricter), which is the opposite of what most people assume.
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

      info = Http.json("https://api.github.com/repos/#{@repo}", headers: gh_headers)
      return { present: false, reason: "Repo not found or private: #{@repo}" } unless info && info["full_name"]

      branch = info["default_branch"]
      file, text = license_text(branch)
      klass = classify(text)
      swh = archived_in_swh?

      {
        present: true, repo: info["full_name"], stars: info["stargazers_count"],
        forks: info["forks_count"], created: info["created_at"].to_s[0, 10],
        github_spdx: info.dig("license", "spdx_id") || "NONE",
        license_file: file, license_class: klass, license_label: label(text),
        github_mislabels: mislabels?(info, klass),
        swh_archived: swh,
        kept_by_stack: KEPT_BY_STACK[klass],
        checks: [
          { name: "Public on GitHub", pass: true, detail: "#{info['full_name']} (#{info['stargazers_count']} stars)",
            why: "Public code is the channel that skips the web quality filter." },
          { name: "Collected by Software Heritage", pass: swh,
            detail: swh ? "archived" : "not archived",
            why: "The Stack v2/v3 are built from the SWH archive. Not archived means not collected, whatever the license says." },
          { name: "License permits inclusion", pass: KEPT_BY_STACK[klass] == true,
            detail: license_detail(klass, file, text),
            why: "Corpora drop non_permissive files by name. A missing license is NOT a disqualifier for The Stack v2/v3." }
        ]
      }
    end

    private

    # Unauthenticated GitHub allows 60 requests/hour, which a single busy demo can exhaust; a token
    # raises that to 5000. Optional, so the analyzer still works without one.
    def gh_headers
      t = AnalyzerConfig.github_token.to_s
      t.empty? ? {} : { "Authorization" => "Bearer #{t}" }
    end

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
  end
end
