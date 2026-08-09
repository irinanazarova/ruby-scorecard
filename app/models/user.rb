# frozen_string_literal: true

class User < ApplicationRecord
  has_many :analyses, dependent: :nullify

  # Spend is tracked in tenths of a cent against RubyLLM's reported per-message cost, not an
  # estimate from token counts. A probe costs ~0.3c, so whole-cent accounting would round most of
  # the bill to zero and the cap would never fire.
  def budget_millicents = AnalyzerConfig.budget_cents_per_user * 10

  def remaining_millicents = [ budget_millicents - spent_millicents, 0 ].max

  def budget_exhausted? = remaining_millicents <= 0

  def spend!(millicents)
    return if millicents.to_i <= 0

    increment!(:spent_millicents, millicents.to_i)
  end

  def spent_dollars = (spent_millicents / 1000.0).round(2)
  def budget_dollars = (budget_millicents / 1000.0).round(2)

  def self.from_github(auth)
    user = find_or_initialize_by(github_uid: auth["uid"].to_s)
    info = auth["info"] || {}
    user.login = info["nickname"].presence || "unknown"
    user.name = info["name"]
    user.avatar_url = info["image"]
    user.save!
    user
  end
end
