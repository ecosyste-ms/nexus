class CleanupOldIndexesWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform
    retention_days = ENV.fetch('INDEX_RETENTION_DAYS', 7).to_i
    cutoff_time = retention_days.days.ago

    work_dir = Rails.root.join('tmp', 'maven-indexes')
    return unless Dir.exist?(work_dir)

    Rails.logger.info "Cleaning up index files older than #{retention_days} days"

    Dir.glob(File.join(work_dir, '*')).each do |repo_dir|
      next unless File.directory?(repo_dir)
      next unless File.mtime(repo_dir) < cutoff_time

      FileUtils.rm_rf(repo_dir)
      Rails.logger.info "Removed old index directory: #{repo_dir}"
    end
  end
end
