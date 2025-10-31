class CreateVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :versions do |t|
      t.references :package, null: false, foreign_key: true
      t.string :number, null: false
      t.datetime :last_modified
      t.string :packaging
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :versions, [:package_id, :number], unique: true
    add_index :versions, :last_modified
  end
end
