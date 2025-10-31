class CreatePackages < ActiveRecord::Migration[8.0]
  def change
    create_table :packages do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :name, null: false
      t.string :group_id, null: false
      t.string :artifact_id, null: false
      t.datetime :last_modified
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :packages, [:repository_id, :name], unique: true
    add_index :packages, :group_id
    add_index :packages, :artifact_id
    add_index :packages, :last_modified
  end
end
