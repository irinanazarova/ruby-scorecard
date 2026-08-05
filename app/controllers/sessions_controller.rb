# frozen_string_literal: true

# GitHub sign-in exists for exactly one reason: to attach model spend to a person so it can be
# capped. No scopes are requested, nothing is written to anyone's account, and analyses run fine
# without signing in until the free allowance is used up.
class SessionsController < ApplicationController
  def create
    auth = request.env["omniauth.auth"]
    return redirect_to(test_path, alert: "GitHub sign-in failed.") if auth.blank?

    user = User.from_github(auth)
    session[:user_id] = user.id

    # Carry anonymous runs from this browser over, so signing in does not appear to lose history.
    Analysis.where(session_token: session_token, user_id: nil).update_all(user_id: user.id)

    redirect_to test_path, notice: "Signed in as #{user.login}. Budget: $#{user.budget_dollars}."
  end

  def failure
    redirect_to test_path, alert: "GitHub sign-in was cancelled or failed."
  end

  def destroy
    session.delete(:user_id)
    redirect_to test_path, notice: "Signed out."
  end
end
