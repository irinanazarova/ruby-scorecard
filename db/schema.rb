# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_05_031152) do
  create_table "analyses", force: :cascade do |t|
    t.integer "cost_millicents", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "from_cache", default: false, null: false
    t.string "input", null: false
    t.string "ip_hash"
    t.string "kind"
    t.json "results"
    t.string "session_token", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["ip_hash", "created_at"], name: "index_analyses_on_ip_hash_and_created_at"
    t.index ["session_token"], name: "index_analyses_on_session_token"
    t.index ["user_id"], name: "index_analyses_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.integer "analyses_count", default: 0, null: false
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "github_uid", null: false
    t.string "login", null: false
    t.string "name"
    t.integer "spent_millicents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["github_uid"], name: "index_users_on_github_uid", unique: true
  end

  add_foreign_key "analyses", "users"
end
