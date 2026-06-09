# Disposable image for running the Common Crawl coverage probe from a Fly machine,
# i.e. from a throwaway IP, so the home/office IP is never at risk of a rate-limit block.
# Built + run + torn down by fetch/run-on-fly.sh.
FROM ruby:3.4-alpine
RUN apk add --no-cache curl
WORKDIR /app
COPY scripts/coverage.rb scripts/coverage.rb
COPY data/scorecard.json data/scorecard.json
# Stay alive so the probe can be exec'd over `fly ssh console -C` and its stdout captured.
CMD ["sleep", "infinity"]
