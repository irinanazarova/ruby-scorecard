# Disposable image for running the scorecard probes from a Fly machine.
#
# Two reasons, and the second is the one that bites daily:
#   - Common Crawl's CDX index is IP rate-limited, so a home/office IP risks a 24h block.
#   - A home connection that drops mid-run makes probe.rb record "unreachable" for every
#     resource after the drop, which reads as dozens of projects deleting their sitemap and
#     llms.txt at once. A datacentre machine does not drop.
# Built + run + torn down by fetch/run-on-fly.sh.
FROM ruby:3.4-alpine
RUN apk add --no-cache curl
WORKDIR /app
COPY scripts/probe.rb scripts/probe.rb
COPY scripts/coverage.rb scripts/coverage.rb
COPY scripts/coverage_details.rb scripts/coverage_details.rb
COPY data/scorecard.json data/scorecard.json
# Stay alive so the probe can be exec'd over `fly ssh console -C` and its stdout captured.
CMD ["sleep", "infinity"]
