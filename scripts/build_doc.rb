#!/usr/bin/env ruby
# frozen_string_literal: true

# Render a Markdown doc into a styled, self-contained HTML (and, via headless Chrome, a PDF) optimized
# for reading: generous measure, real typography, clickable links, a table of contents, print styles.
#
#   ruby scripts/build_doc.rb docs/how-devtooling-gets-into-training-data.md
#
# Produces <same-path>.html. Run build_doc_pdf.sh afterwards (or build.sh) for the PDF.

require "redcarpet"

ROOT = File.expand_path("..", __dir__)
src = ARGV[0] || File.join(ROOT, "docs", "how-devtooling-gets-into-training-data.md")
abort "no #{src}" unless File.exist?(src)

raw = File.read(src)

def slugify(text)
  text.gsub(/<[^>]+>/, "").gsub(/&#?\w+;/, "").downcase.gsub(/[^\w\s-]/, "").strip.gsub(/\s+/, "-")
end

# Pull the H1 title + the first paragraph as a lead, leave the rest as the body.
lines = raw.lines
title = (lines.shift&.sub(/^#\s*/, "")&.strip) || "Document"
lines.shift while lines.first && lines.first.strip.empty?
lead = +""
lead << lines.shift while lines.first && !lines.first.strip.empty?
lead = lead.strip
body_md = lines.join

# The header date comes from the document's own "Last updated" footer. Hardcoding it here meant
# the header and the footer drifted apart the first time the doc was revised.
updated = raw[/_Last updated (\d{4}-\d{2}-\d{2})/, 1] || Time.now.strftime("%Y-%m-%d")

# Table of contents from the H2 headings.
toc = body_md.scan(/^##\s+(.+)$/).flatten.map do |h|
  plain = h.gsub(/`/, "")
  %(<li><a href="##{slugify(plain)}">#{plain}</a></li>)
end.join("\n")

class DocRenderer < Redcarpet::Render::HTML
  def header(text, level)
    %(<h#{level} id="#{slugify(text)}">#{text}</h#{level}>\n)
  end
end

renderer = DocRenderer.new(link_attributes: { target: "_blank", rel: "noopener noreferrer" }, hard_wrap: false)
markdown = Redcarpet::Markdown.new(renderer,
  tables: true, fenced_code_blocks: true, autolink: true, strikethrough: true,
  no_intra_emphasis: true, lax_spacing: true, space_after_headers: true, underline: true)
lead_html = Redcarpet::Markdown.new(renderer, autolink: true).render(lead)
body_html = markdown.render(body_md)

css = <<~CSS
  :root {
    --ink: #1a1420; --muted: #5f5763; --accent: #ff533e; --accent-ink: #c5341f;
    --bg: #fffdfa; --panel: #fbf6ee; --line: #e9e0d4; --code-bg: #f3ece2;
    --measure: 46rem;
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0; color: var(--ink); background: var(--bg);
    font: 18px/1.7 "Charter", "Bitstream Charter", "Iowan Old Style", "Georgia", serif;
    font-feature-settings: "kern", "liga"; text-rendering: optimizeLegibility;
  }
  .wrap { max-width: var(--measure); margin: 0 auto; padding: 4rem 1.5rem 6rem; }
  h1, h2, h3, h4, .kicker, .toc-title, code, th {
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  .kicker {
    font-size: .72rem; letter-spacing: .14em; text-transform: uppercase;
    color: var(--accent-ink); font-weight: 600; margin: 0 0 1rem;
  }
  h1 { font-size: 2.5rem; line-height: 1.1; letter-spacing: -.02em; margin: 0 0 1rem; font-weight: 800; }
  .lead { font-size: 1.18rem; color: var(--muted); line-height: 1.6; margin: 0 0 1.5rem; }
  .meta { font-size: .8rem; color: var(--muted); font-family: "Inter", sans-serif;
          border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); padding: .75rem 0; margin-bottom: 2.5rem; }
  h2 { font-size: 1.6rem; line-height: 1.2; letter-spacing: -.01em; font-weight: 750;
       margin: 3rem 0 1rem; padding-top: 1.25rem; border-top: 3px solid var(--accent); }
  h3 { font-size: 1.18rem; font-weight: 700; margin: 2rem 0 .6rem; }
  p, li { overflow-wrap: break-word; }
  p { margin: 0 0 1.1rem; }
  a { color: var(--accent-ink); text-underline-offset: 2px; text-decoration-thickness: .06em; }
  a:hover { color: var(--accent); }
  strong { font-weight: 700; }
  ul, ol { padding-left: 1.3rem; margin: 0 0 1.2rem; }
  li { margin: .35rem 0; }
  code { font-size: .86em; background: var(--code-bg); padding: .12em .38em; border-radius: 4px;
         border: 1px solid var(--line); }
  pre { background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
        padding: 1rem 1.1rem; overflow-x: auto; margin: 0 0 1.3rem; line-height: 1.5; }
  pre code { background: none; border: none; padding: 0; font-size: .82rem; }
  blockquote { margin: 0 0 1.3rem; padding: .4rem 0 .4rem 1.2rem; border-left: 4px solid var(--accent);
               color: var(--muted); font-style: italic; }
  hr { border: none; border-top: 1px solid var(--line); margin: 2.5rem 0; }
  table { width: 100%; border-collapse: collapse; margin: 0 0 1.4rem; font-size: .9rem;
          font-family: "Inter", sans-serif; }
  th, td { text-align: left; padding: .55rem .7rem; border: 1px solid var(--line); vertical-align: top; }
  th { background: var(--panel); font-weight: 600; font-size: .8rem; letter-spacing: .01em; }
  tbody tr:nth-child(even) { background: #fdfaf5; }
  td code, th code { font-size: .82em; }
  .toc { background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
         padding: 1.1rem 1.4rem; margin: 0 0 2.5rem; font-family: "Inter", sans-serif; }
  .toc-title { font-size: .72rem; letter-spacing: .12em; text-transform: uppercase; color: var(--muted);
               margin: 0 0 .6rem; font-weight: 600; }
  .toc ol { margin: 0; padding-left: 1.1rem; columns: 2; column-gap: 2rem; font-size: .9rem; }
  .toc li { margin: .25rem 0; }
  .toc a { color: var(--ink); text-decoration: none; }
  .toc a:hover { color: var(--accent-ink); text-decoration: underline; }
  footer { margin-top: 3rem; padding-top: 1.2rem; border-top: 1px solid var(--line);
           font-size: .8rem; color: var(--muted); font-family: "Inter", sans-serif; }

  @media (max-width: 560px) { .toc ol { columns: 1; } h1 { font-size: 2rem; } body { font-size: 17px; } }

  @media print {
    :root { --bg: #fff; }
    @page { margin: 18mm 16mm; }
    body { font-size: 10.5pt; line-height: 1.5; }
    .wrap { max-width: none; padding: 0; }
    a { color: var(--accent-ink); }
    h1 { font-size: 22pt; }
    h2 { font-size: 15pt; margin-top: 1.4rem; break-after: avoid; }
    h3 { break-after: avoid; }
    pre, table, blockquote, tr, img { break-inside: avoid; }
    .toc { break-inside: avoid; }
    footer { break-before: avoid; }
  }
CSS

html = <<~HTML
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{title}</title>
    <style>#{css}</style>
  </head>
  <body>
    <article class="wrap">
      <p class="kicker">Evil Martians &middot; Ruby &middot; LLM discoverability</p>
      <h1>#{title}</h1>
      <div class="lead">#{lead_html.sub(/\A<p>/, "").sub(/<\/p>\s*\z/, "")}</div>
      <p class="meta">Research note &middot; last updated #{updated} &middot; every major fact links a primary source</p>
      <nav class="toc">
        <p class="toc-title">Contents</p>
        <ol>#{toc}</ol>
      </nav>
      #{body_html}
      <footer>Generated from <code>#{File.basename(src)}</code>. Findings marked &ldquo;(measured)&rdquo;
      are reproducible via <code>scripts/quality_core.rb</code> and <code>scripts/coverage_details.rb</code> in this repo.</footer>
    </article>
  </body>
  </html>
HTML

out = src.sub(/\.md\z/, ".html")
File.write(out, html)
warn "wrote #{out} (#{(html.bytesize / 1024.0).round(1)} KB)"
