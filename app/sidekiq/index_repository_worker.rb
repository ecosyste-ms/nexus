class IndexRepositoryWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  def perform(repository_id)
    repository = Repository.find(repository_id)
    service = IndexRepositoryService.new(repository)
    result = service.call

    Rails.logger.info "Indexed repository #{repository.name}: #{result[:package_count]} packages"
  rescue StandardError => e
    Rails.logger.error "Failed to index repository #{repository_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end
