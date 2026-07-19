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

ActiveRecord::Schema[8.1].define(version: 2026_07_19_120001) do
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
    t.index ["tenant"], name: "index_rbrun_sessions_on_tenant"
  end

  add_foreign_key "rbrun_session_messages", "rbrun_sessions", column: "session_id"
end
