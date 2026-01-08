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

ActiveRecord::Schema[8.1].define(version: 2025_11_22_185250) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "packages", force: :cascade do |t|
    t.string "artifact_id", null: false
    t.datetime "created_at", null: false
    t.string "group_id", null: false
    t.datetime "last_modified"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.bigint "repository_id", null: false
    t.datetime "updated_at", null: false
    t.index ["artifact_id"], name: "index_packages_on_artifact_id"
    t.index ["group_id"], name: "index_packages_on_group_id"
    t.index ["last_modified"], name: "index_packages_on_last_modified"
    t.index ["repository_id", "name"], name: "index_packages_on_repository_id_and_name", unique: true
    t.index ["repository_id"], name: "index_packages_on_repository_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ecosystem", default: "maven"
    t.text "error_message"
    t.string "index_chain_id"
    t.bigint "index_size_bytes"
    t.string "index_timestamp"
    t.integer "last_incremental_chunk"
    t.datetime "last_indexed_at"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.integer "package_count", default: 0
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["last_indexed_at"], name: "index_repositories_on_last_indexed_at"
    t.index ["name"], name: "index_repositories_on_name", unique: true
    t.index ["status"], name: "index_repositories_on_status"
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_modified"
    t.jsonb "metadata", default: {}
    t.string "number", null: false
    t.bigint "package_id", null: false
    t.string "packaging"
    t.datetime "updated_at", null: false
    t.index ["last_modified"], name: "index_versions_on_last_modified"
    t.index ["package_id", "number"], name: "index_versions_on_package_id_and_number", unique: true
    t.index ["package_id"], name: "index_versions_on_package_id"
  end

  add_foreign_key "packages", "repositories"
  add_foreign_key "versions", "packages"
end
