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

ActiveRecord::Schema[8.1].define(version: 2026_07_19_130003) do
  create_table "rbrun_commits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "message"
    t.integer "session_id"
    t.string "sha", null: false
    t.datetime "updated_at", null: false
    t.integer "worktree_id", null: false
    t.index ["session_id"], name: "index_rbrun_commits_on_session_id"
    t.index ["worktree_id", "sha"], name: "index_rbrun_commits_on_worktree_id_and_sha", unique: true
    t.index ["worktree_id"], name: "index_rbrun_commits_on_worktree_id"
  end

  create_table "rbrun_session_messages", force: :cascade do |t|
    t.string "approval_status"
    t.text "content"
    t.datetime "created_at", null: false
    t.string "event_type"
    t.json "payload", default: {}, null: false
    t.string "role"
    t.integer "session_id", null: false
    t.string "tool_use_id"
    t.datetime "updated_at", null: false
    t.bigint "user_message_id"
    t.index ["event_type"], name: "index_rbrun_session_messages_on_event_type"
    t.index ["session_id", "approval_status"], name: "idx_rbrun_msgs_pending", where: "approval_status IS NOT NULL"
    t.index ["session_id"], name: "index_rbrun_session_messages_on_session_id"
    t.index ["tool_use_id"], name: "index_rbrun_session_messages_on_tool_use_id"
  end

  create_table "rbrun_sessions", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "sdk_session_id"
    t.string "status", default: "idle", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.integer "worktree_id", null: false
    t.index ["tenant"], name: "index_rbrun_sessions_on_tenant"
    t.index ["worktree_id"], name: "index_rbrun_sessions_on_worktree_id"
  end

  create_table "rbrun_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_rbrun_users_on_email", unique: true
  end

  create_table "rbrun_worktrees", force: :cascade do |t|
    t.string "base", default: "main", null: false
    t.string "branch", null: false
    t.datetime "created_at", null: false
    t.string "repo", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant"], name: "index_rbrun_worktrees_on_tenant"
  end

  add_foreign_key "rbrun_commits", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_commits", "rbrun_worktrees", column: "worktree_id"
  add_foreign_key "rbrun_session_messages", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_sessions", "rbrun_worktrees", column: "worktree_id"
end
