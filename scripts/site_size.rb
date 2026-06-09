#!/usr/bin/env ruby
# frozen_string_literal: true

# Estimates total pages per sampled domain (sitemap count, else a capped crawl) so the
# Common Crawl coverage percentages in build.rb can be sanity-checked. The CC index
# rate-limits bulk queries, so the CC numerators are constants, queried a few at a time.

require "uri"
require "open3"

UA = "Mozilla/5.0 (research)"

def fetch(url, timeout = 12)
  out, _err, _st = Open3.capture3("curl", "-sL", "--max-time", timeout.to_s, "-A", UA, url)
  out
rescue StandardError
  ""
end

def host(url) = URI.parse(url).host.to_s.sub(/\Awww\./, "")

def sitemap_total(base)
  candidates = []
  fetch("#{base}/robots.txt", 8).each_line do |l|
    candidates << l.split(":", 2)[1].to_s.strip if l.strip.downcase.start_with?("sitemap:")
  end
  candidates += ["#{base}/sitemap.xml", "#{base}/sitemap_index.xml", "#{base}/sitemap-index.xml"]

  candidates.each do |sm|
    xml = fetch(sm, 20)
    next unless xml.include?("<loc>")

    if xml.include?("<sitemapindex")
      children = xml.scan(%r{<loc>\s*([^<]+?)\s*</loc>}).flatten
      total = children.first(40).sum { |c| fetch(c.strip, 20).scan("<loc>").size }
      return [total, "sitemap-index"]
    end
    return [xml.scan("<loc>").size, "sitemap"]
  end
  [nil, nil]
end

def crawl_est(base, cap: 300, fanout: 70)
  h = host(base)
  norm = ->(u) { u.split("#").first.sub(%r{/\z}, "") }
  skip_ext = %w[.css .js .png .jpg .jpeg .svg .gif .pdf .zip .xml .ico .woff .woff2 .webp]

  links = lambda do |html, current|
    found = []
    html.scan(/href=["']([^"']+)["']/).flatten.each do |m|
      next if m.start_with?("mailto:", "javascript:", "tel:", "data:")

      full = begin
        URI.join(current, m).to_s
      rescue StandardError
        next
      end
      next unless full.start_with?("http")
      next if skip_ext.any? { |e| full.downcase.end_with?(e) }

      found << norm.call(full) if host(full) == h
    end
    found.uniq
  end

  home = fetch(base)
  l1 = links.call(home, base)
  seen = ([norm.call(base)] + l1).uniq
  fetched = 0
  l1.each do |u|
    break if fetched >= fanout || seen.size >= cap

    seen = (seen + links.call(fetch(u), u)).uniq
    fetched += 1
  end
  [[seen.size, cap].min, seen.size >= cap ? "crawl-capped" : "crawl"]
end

CC = {
  "https://guides.rubyonrails.org" => 165,
  "https://inertia-rails.dev" => 19,
  "https://turbo.hotwired.dev" => 6,
  "https://www.rubyevents.org" => 1
}.freeze

CC.each do |base, cc|
  total, method = sitemap_total(base)
  total, method = crawl_est(base) if total.nil?
  pct = total && total.positive? ? "#{(100.0 * cc / total).round}%" : "?"
  puts "#{base} | CC #{cc} / ~#{total} (#{pct}) | via #{method}"
  $stdout.flush
end
puts "DONE"
