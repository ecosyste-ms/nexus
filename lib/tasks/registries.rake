namespace :registries do
  desc "Sync registries from packages.ecosyste.ms"
  task sync: :environment do
    packages_url = ENV.fetch('PACKAGES_ECOSYSTE_MS_URL', 'https://packages.ecosyste.ms')
    api_url = "#{packages_url}/api/v1/registries"

    puts "Fetching registries from #{api_url}..."

    conn = Faraday.new do |f|
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
    end

    response = conn.get(api_url)

    unless response.success?
      puts "Error: Failed to fetch registries (#{response.status})"
      exit 1
    end

    registries = JSON.parse(response.body)

    # Filter for Maven registries
    maven_registries = registries.select do |registry|
      registry['ecosystem'] == 'maven'
    end

    puts "Found #{maven_registries.count} Maven registries"

    synced = []
    maven_registries.each do |registry_data|
      repo = Repository.find_or_initialize_by(name: registry_data['name'])
      repo.url = registry_data['url']
      repo.ecosystem = registry_data['ecosystem']
      repo.status = 'pending' if repo.new_record?

      if repo.save
        synced << repo.name
        puts "  ✓ #{repo.name}"
      else
        puts "  ✗ Failed to save #{registry_data['name']}: #{repo.errors.full_messages.join(', ')}"
      end
    end

    puts "\nSynced #{synced.count} repositories"
  end

  desc "Index all repositories that need reindexing"
  task index_all: :environment do
    repositories = Repository.where('last_indexed_at IS NULL OR last_indexed_at < ?', reindex_interval.ago)

    puts "Queueing #{repositories.count} repositories for indexing..."

    repositories.find_each do |repository|
      IndexRepositoryWorker.perform_async(repository.id)
      puts "  ✓ Queued #{repository.name}"
    end

    puts "\nIndexing jobs queued. Check Sidekiq for progress."
  end

  desc "Index a specific repository by name"
  task :index, [:name] => :environment do |t, args|
    unless args[:name]
      puts "Error: Repository name required"
      puts "Usage: rake registries:index[repository_name]"
      exit 1
    end

    repository = Repository.find_by(name: args[:name])

    unless repository
      puts "Error: Repository '#{args[:name]}' not found"
      exit 1
    end

    IndexRepositoryWorker.perform_async(repository.id)
    puts "Queued #{repository.name} for indexing"
  end

  desc "Show index metadata for all repositories"
  task index_status: :environment do
    repositories = Repository.all.order(:name)

    puts "\n#{'Repository'.ljust(50)} Status      Last Indexed           Chain ID        Chunk"
    puts "-" * 120

    repositories.each do |repo|
      last_indexed = repo.last_indexed_at ? repo.last_indexed_at.strftime('%Y-%m-%d %H:%M') : 'Never'
      chain_id = repo.index_chain_id || 'N/A'
      chunk = repo.last_incremental_chunk || 'N/A'

      puts "#{repo.name.ljust(50)} #{repo.status.ljust(11)} #{last_indexed.ljust(22)} #{chain_id.ljust(15)} #{chunk}"
    end

    puts "\nTotal repositories: #{repositories.count}"
    puts "Completed: #{Repository.completed.count}"
    puts "Failed: #{Repository.failed.count}"
    puts "Pending: #{Repository.pending.count}"
  end

  def reindex_interval
    ENV.fetch('REINDEX_INTERVAL_HOURS', 24).to_i.hours
  end
end
