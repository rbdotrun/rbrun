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

ActiveRecord::Schema[8.1].define(version: 2026_07_23_180000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "rbrun_artifact_versions", force: :cascade do |t|
    t.integer "artifact_id", null: false
    t.datetime "created_at", null: false
    t.integer "message_id"
    t.integer "number", null: false
    t.datetime "updated_at", null: false
    t.index ["artifact_id", "number"], name: "index_rbrun_artifact_versions_on_artifact_id_and_number", unique: true
    t.index ["artifact_id"], name: "index_rbrun_artifact_versions_on_artifact_id"
    t.index ["message_id"], name: "index_rbrun_artifact_versions_on_message_id"
  end

  create_table "rbrun_artifacts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.string "name", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant"], name: "index_rbrun_artifacts_on_tenant"
  end

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

  create_table "rbrun_deploy_targets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "deploy_tag"
    t.string "deployed_sha"
    t.string "host", null: false
    t.string "image", null: false
    t.text "last_deploy_log"
    t.string "provider", null: false
    t.string "region", null: false
    t.string "server_id"
    t.string "server_ip"
    t.string "server_type", null: false
    t.text "ssh_private_key"
    t.text "ssh_public_key"
    t.string "status", default: "pending", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.integer "worktree_id", null: false
    t.index ["worktree_id"], name: "index_rbrun_deploy_targets_on_worktree_id", unique: true
  end

  create_table "rbrun_mcp_servers", force: :cascade do |t|
    t.json "args", default: []
    t.string "auth"
    t.string "command"
    t.string "config_digest"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.json "env", default: {}
    t.json "headers", default: {}
    t.string "name", null: false
    t.string "tenant", null: false
    t.json "tool_permissions", default: {}
    t.json "tools"
    t.string "transport", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["tenant", "name"], name: "index_rbrun_mcp_servers_on_tenant_and_name", unique: true
  end

  create_table "rbrun_repo_secrets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "repo", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["tenant", "repo", "key"], name: "idx_rbrun_repo_secrets_uniq", unique: true
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

  create_table "rbrun_session_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.integer "session_id", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "idx_rbrun_session_snapshots_uniq", unique: true
  end

  create_table "rbrun_sessions", force: :cascade do |t|
    t.datetime "archived_at"
    t.boolean "auto", default: false, null: false
    t.datetime "created_at", null: false
    t.json "preferred_skills", default: [], null: false
    t.string "sdk_session_id"
    t.string "status", default: "idle", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id"
    t.string "workflow_status"
    t.integer "worktree_id", null: false
    t.index ["tenant"], name: "index_rbrun_sessions_on_tenant"
    t.index ["workflow_id"], name: "index_rbrun_sessions_on_workflow_id"
    t.index ["worktree_id"], name: "index_rbrun_sessions_on_worktree_id"
  end

  create_table "rbrun_skill_scenarios", force: :cascade do |t|
    t.json "attachments", default: [], null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "label", null: false
    t.text "prompt", null: false
    t.integer "skill_id", null: false
    t.json "steps", default: [], null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_id"], name: "index_rbrun_skill_scenarios_on_skill_id"
    t.index ["tenant", "skill_id", "label"], name: "idx_rbrun_skill_scenarios_unique", unique: true
  end

  create_table "rbrun_skill_versions", force: :cascade do |t|
    t.binary "archive", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.integer "skill_id", null: false
    t.string "source", null: false
    t.index ["skill_id", "digest"], name: "index_rbrun_skill_versions_on_skill_id_and_digest", unique: true
    t.index ["skill_id"], name: "index_rbrun_skill_versions_on_skill_id"
  end

  create_table "rbrun_skills", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.string "dismissed_digest"
    t.string "divergence_digest"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant", "slug"], name: "index_rbrun_skills_on_tenant_and_slug", unique: true
  end

  create_table "rbrun_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_rbrun_users_on_email", unique: true
  end

  create_table "rbrun_workflow_step_completions", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "session_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_message_id"
    t.integer "workflow_step_id", null: false
    t.index ["session_id", "workflow_step_id"], name: "idx_rbrun_wsc_session_step", unique: true
    t.index ["session_id"], name: "index_rbrun_workflow_step_completions_on_session_id"
    t.index ["user_message_id"], name: "index_rbrun_workflow_step_completions_on_user_message_id"
    t.index ["workflow_step_id"], name: "index_rbrun_workflow_step_completions_on_workflow_step_id"
  end

  create_table "rbrun_workflow_steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "position", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["workflow_id"], name: "index_rbrun_workflow_steps_on_workflow_id"
  end

  create_table "rbrun_workflows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.text "goal"
    t.string "label", null: false
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant"], name: "index_rbrun_workflows_on_tenant"
  end

  create_table "rbrun_worktrees", force: :cascade do |t|
    t.datetime "archived_at"
    t.boolean "bare", default: false, null: false
    t.string "base", default: "main", null: false
    t.string "branch", null: false
    t.datetime "created_at", null: false
    t.string "repo", null: false
    t.string "sandbox_provider"
    t.string "tenant", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant"], name: "index_rbrun_worktrees_on_tenant"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "rbrun_artifact_versions", "rbrun_artifacts", column: "artifact_id"
  add_foreign_key "rbrun_artifact_versions", "rbrun_session_messages", column: "message_id", on_delete: :nullify
  add_foreign_key "rbrun_commits", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_commits", "rbrun_worktrees", column: "worktree_id"
  add_foreign_key "rbrun_deploy_targets", "rbrun_worktrees", column: "worktree_id"
  add_foreign_key "rbrun_session_messages", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_session_snapshots", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_sessions", "rbrun_workflows", column: "workflow_id"
  add_foreign_key "rbrun_sessions", "rbrun_worktrees", column: "worktree_id"
  add_foreign_key "rbrun_skill_scenarios", "rbrun_skills", column: "skill_id"
  add_foreign_key "rbrun_skill_versions", "rbrun_skills", column: "skill_id"
  add_foreign_key "rbrun_workflow_step_completions", "rbrun_session_messages", column: "user_message_id", on_delete: :nullify
  add_foreign_key "rbrun_workflow_step_completions", "rbrun_sessions", column: "session_id"
  add_foreign_key "rbrun_workflow_step_completions", "rbrun_workflow_steps", column: "workflow_step_id"
  add_foreign_key "rbrun_workflow_steps", "rbrun_workflows", column: "workflow_id"
end
