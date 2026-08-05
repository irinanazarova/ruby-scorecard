# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Analyzer
  # One tiny HTTP helper for every check, so timeouts and the user agent are consistent and a slow
  # third party can never hang a request. Every check runs against someone else's server.
  module Http
    UA = "trained-on/1.0 (+https://trained-on.fly.dev; corpus-visibility probe)"
    CCBOT = "CCBot/2.0 (https://commoncrawl.org/faq/)"

    module_function

    def get(url, headers: {}, timeout: 12, limit: 4)
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP)

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = headers.delete("User-Agent") || UA
      headers.each { |k, v| req[k] = v }

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: timeout, read_timeout: timeout) { |h| h.request(req) }

      if res.is_a?(Net::HTTPRedirection) && limit.positive?
        return get(URI.join(url, res["location"]).to_s, headers:, timeout:, limit: limit - 1)
      end

      res
    rescue StandardError
      nil
    end

    # Status + content type without downloading the body twice.
    def probe(url, headers: {}, timeout: 12)
      res = get(url, headers:, timeout:)
      return { ok: false, status: nil, type: nil, body: nil } unless res

      { ok: res.is_a?(Net::HTTPSuccess), status: res.code.to_i,
        type: res["content-type"].to_s.split(";").first, body: utf8(res.body) }
    end

    # Net::HTTP hands back ASCII-8BIT whenever the response omits a charset, and every downstream
    # regex here is UTF-8, so matching one against the other raises Encoding::CompatibilityError and
    # the rescue in `get` turns a perfectly good page into "could not fetch". scrub drops the bytes
    # that are not valid UTF-8 rather than raising on them.
    def utf8(body)
      return nil if body.nil?

      body.dup.force_encoding(Encoding::UTF_8).scrub("")
    end

    def json(url, headers: {}, timeout: 20)
      res = get(url, headers:, timeout:)
      return nil unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(utf8(res.body))
    rescue JSON::ParserError
      nil
    end

    def post_json(url, payload, headers: {}, timeout: 60)
      uri = URI.parse(url)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["User-Agent"] = UA
      headers.each { |k, v| req[k] = v }
      req.body = payload.to_json
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: timeout, read_timeout: timeout) { |h| h.request(req) }
      res.is_a?(Net::HTTPSuccess) ? JSON.parse(utf8(res.body)) : nil
    rescue StandardError
      nil
    end
  end
end
