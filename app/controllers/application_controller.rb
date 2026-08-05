# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user, :signed_in?, :session_token, :free_remaining, :anycable_token

  # Short-lived JWT the browser presents to AnyCable. RPC-less means AnyCable cannot ask Rails
  # whether a visitor may connect, so the token IS the answer — without it every socket is dropped
  # as "unauthorized" before any subscription is attempted.
  #
  # Returns nil unless AnyCable is the configured adapter, so development on the async adapter
  # renders no token and the JS skips building a cable entirely.
  def anycable_token
    return @anycable_token if defined?(@anycable_token)

    @anycable_token =
      if ActionCable.server.config.cable[:adapter].to_s == "any_cable" && AnyCable.config.secret.present?
        AnyCable::JWT.encode({ sid: session_token }, expires_at: 6.hours.from_now)
      end
  rescue StandardError => e
    Rails.logger.error("[anycable] token generation failed: #{e.class} #{e.message}")
    @anycable_token = nil
  end

  private

  def current_user
    @current_user ||= (User.find_by(id: session[:user_id]) if session[:user_id])
  end

  def signed_in? = current_user.present?

  # A stable per-browser token. The anonymous allowance is counted against this rather than the IP,
  # so a room full of people behind one conference NAT do not consume each other's free runs. It is
  # trivially reset by clearing cookies, which is fine: the IP rate limit and the per-user budget
  # are what actually protect the account.
  def session_token
    session[:analyzer_token] ||= SecureRandom.uuid
  end

  def free_remaining = Analysis.free_remaining(session_token)

  # Never store raw IPs. They are only needed to count requests, and a salted hash counts just as
  # well while keeping the database free of personal data.
  def ip_hash
    Digest::SHA256.hexdigest("#{Rails.application.secret_key_base}:#{request.remote_ip}")[0, 32]
  end
end
