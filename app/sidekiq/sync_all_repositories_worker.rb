class SyncAllRepositoriesWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 2

  def perform
    repositories = Repository.where('last_indexed_at IS NULL OR last_indexed_at < ?', reindex_interval.ago)

    Rails.logger.info "Syncing #{repositories.count} repositories that need indexing"

    repositories.find_each do |repository|
      IndexRepositoryWorker.perform_async(repository.id)
    end
  end

  private

  def reindex_interval
    ENV.fetch('REINDEX_INTERVAL_HOURS', 24).to_i.hours
  end
end
