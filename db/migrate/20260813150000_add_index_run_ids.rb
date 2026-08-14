class AddIndexRunIds < ActiveRecord::Migration[8.1]
  def change
    add_column :packages, :index_run_id, :uuid
    add_column :versions, :index_run_id, :uuid

    add_index :packages, [:repository_id, :index_run_id]
    add_index :versions, [:package_id, :index_run_id]
  end
end
