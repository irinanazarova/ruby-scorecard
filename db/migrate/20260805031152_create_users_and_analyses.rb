# frozen_string_literal: true

class CreateUsersAndAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string  :github_uid, null: false
      t.string  :login, null: false
      t.string  :name
      t.string  :avatar_url
      # Spend is metered in TENTHS of a cent: a single probe costs ~0.3c, so whole cents would round
      # most of the bill away and the cap would never trigger.
      t.integer :spent_millicents, null: false, default: 0
      t.integer :analyses_count, null: false, default: 0
      t.timestamps
    end
    add_index :users, :github_uid, unique: true

    create_table :analyses do |t|
      t.references :user, foreign_key: true          # null for anonymous runs
      t.string  :session_token, null: false          # anonymous quota is per browser session
      t.string  :input, null: false
      t.string  :kind
      t.string  :status, null: false, default: "pending"
      t.integer :cost_millicents, null: false, default: 0
      t.boolean :from_cache, null: false, default: false
      t.string  :ip_hash                             # hashed, never the raw address
      t.json    :results
      t.timestamps
    end
    add_index :analyses, :session_token
    add_index :analyses, %i[ip_hash created_at]
  end
end
