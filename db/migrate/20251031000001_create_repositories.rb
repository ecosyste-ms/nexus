class CreateRepositories < ActiveRecord::Migration[8.0]
  def change
    create_table :repositories do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :ecosystem, default: 'maven'
      t.datetime :last_indexed_at
      t.string :status, default: 'pending'
      t.text :error_message
      t.integer :package_count, default: 0
      t.bigint :index_size_bytes
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :repositories, :name, unique: true
    add_index :repositories, :status
    add_index :repositories, :last_indexed_at
  end
end
