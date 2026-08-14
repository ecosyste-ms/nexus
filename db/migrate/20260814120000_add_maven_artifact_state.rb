class AddMavenArtifactState < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :index_run_id, :uuid
    reversible do |direction|
      direction.up { change_column :repositories, :last_incremental_chunk, :bigint }
      direction.down { change_column :repositories, :last_incremental_chunk, :integer }
    end

    create_table :maven_artifacts, id: false do |t|
      t.references :repository, null: false, foreign_key: true, index: false
      t.string :group_id, null: false
      t.string :artifact_id, null: false
      t.string :version, null: false
      t.string :classifier, null: false, default: ""
      t.string :extension, null: false, default: ""
      t.string :packaging
      t.datetime :last_modified
      t.uuid :index_run_id, null: false
    end

    add_index :maven_artifacts,
              [:repository_id, :group_id, :artifact_id, :version, :classifier, :extension],
              unique: true,
              name: "index_maven_artifacts_on_identity"
    add_index :maven_artifacts, [:repository_id, :index_run_id]
    add_index :packages, [:repository_id, :group_id, :artifact_id]
  end
end
