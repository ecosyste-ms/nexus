class AddIndexMetadataToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :index_timestamp, :string
    add_column :repositories, :index_chain_id, :string
    add_column :repositories, :last_incremental_chunk, :integer
  end
end
