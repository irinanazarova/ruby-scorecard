# frozen_string_literal: true

# Quality-checker HTTP service (Sinatra). POST /api/check {"url": "..."} -> score + feedback.
# Fetches the URL server-side (browsers cannot, cross-origin), guards against SSRF (no private/loopback
# targets, validated on each redirect), caps size, then scores via QualityCore (pure-Ruby FineWeb-Edu).

require "sinatra/base"
require "json"
require "uri"
require "resolv"
require "ipaddr"
require "net/http"
require_relative "../scripts/quality_core"

class CheckApp < Sinatra::Base
  MAX_BYTES = 3_000_000
  RATE_LIMIT = 20
  RATE_WINDOW = 300
  HITS = {}

  class Unsafe < StandardError; end

  configure do
    set :bind, "0.0.0.0"
    set :port, ENV.fetch("PORT", "8080").to_i
    set :server, :puma
    set :show_exceptions, false
    set :logging, true
  end

  before do
    headers "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type"
    content_type :json
  end

  options("*") { 200 }

  get "/healthz" do
    { ok: true }.to_json
  end

  post "/api/check" do
    ip = request.env["HTTP_FLY_CLIENT_IP"] || request.ip
    halt 429, { error: "Rate limit reached. Try again in a few minutes." }.to_json unless rate_ok?(ip)

    payload = (JSON.parse(request.body.read) rescue {})
    url = payload["url"].to_s.strip
    halt 400, { error: "Provide a URL to check." }.to_json if url.empty?
    url = "https://#{url}" unless url.include?("://")

    begin
      html = fetch_safe(url)
    rescue Unsafe => e
      halt 400, { error: e.message }.to_json
    rescue StandardError => e
      halt 400, { error: "Could not fetch the URL (#{e.class.name.split('::').last})." }.to_json
    end

    res = QualityCore.check(html)
    halt 422, { error: res[:error] }.to_json unless res[:ok]
    res.merge(url: url).to_json
  end

  helpers do
    def rate_ok?(ip)
      now = Time.now.to_i
      HITS[ip] = (HITS[ip] || []).select { |t| now - t < RATE_WINDOW }
      HITS[ip] << now
      HITS[ip].size <= RATE_LIMIT
    end

    def validate!(url)
      u = URI.parse(url)
      raise Unsafe, "Only http and https URLs are allowed." unless %w[http https].include?(u.scheme)
      raise Unsafe, "Invalid URL." unless u.host

      addrs = Resolv.getaddresses(u.host)
      raise Unsafe, "Cannot resolve host." if addrs.empty?
      addrs.each do |a|
        ip = IPAddr.new(a)
        if ip.loopback? || ip.private? || ip.link_local?
          raise Unsafe, "Refusing to fetch an internal or private address."
        end
      end
      u
    end

    def fetch_safe(url, depth = 0)
      raise Unsafe, "Too many redirects." if depth > 4
      u = validate!(url)
      http = Net::HTTP.new(u.host, u.port)
      http.use_ssl = u.scheme == "https"
      http.open_timeout = 8
      http.read_timeout = 15
      req = Net::HTTP::Get.new(u.request_uri,
        "User-Agent" => "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com/check)")
      resp = http.request(req)
      case resp
      when Net::HTTPRedirection
        fetch_safe(URI.join(url, resp["location"]).to_s, depth + 1)
      when Net::HTTPSuccess
        (resp.body || "")[0, MAX_BYTES]
      else
        raise "HTTP #{resp.code}"
      end
    end
  end

  run! if __FILE__ == $PROGRAM_NAME
end
