require 'open3'
require 'fileutils'
require 'pathname'
require 'securerandom'
require 'socket'
require 'uri'

class IndexRepositoryService
  MAX_REDIRECTS = 5
  REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

  attr_reader :repository

  def initialize(repository)
    @repository = repository
  end

  def call
    repository.mark_as_indexing!

    # Create work directory
    work_dir = create_work_directory
    gz_file = download_index(work_dir)
    fld_file = export_index(work_dir, gz_file)
    packages_data = parse_index(fld_file)
    Repository.transaction do
      save_packages(packages_data)
      repository.mark_as_completed!(
        package_count: packages_data.keys.count,
        index_size: File.size(gz_file)
      )
    end

    cleanup_files(work_dir) unless keep_files?

    { success: true, package_count: packages_data.keys.count }
  rescue StandardError => e
    repository.mark_as_failed!(e)
    cleanup_files(work_dir) if work_dir && Dir.exist?(work_dir) && !keep_files?
    raise
  end

  def create_work_directory
    raise 'Repository must be persisted before indexing' unless repository.id

    dir = work_root.join(repository.id.to_s).expand_path
    validate_work_directory!(dir)

    FileUtils.mkdir_p(dir)
    dir.to_s
  end

  def download_index(work_dir)
    validate_work_directory!(work_dir)
    gz_file = File.join(work_dir, 'nexus-maven-repository-index.gz')
    url = repository.index_url

    Rails.logger.info "Downloading index from #{url}"

    response = download_response(url)

    raise "Failed to download index: #{response.status}" unless response.status == 200

    File.open(gz_file, 'wb') { |f| f.write(response.body) }
    gz_file
  end

  def export_index(work_dir, gz_file)
    validate_work_directory!(work_dir)
    Rails.logger.info "Exporting index using Docker"

    export_dir = File.join(work_dir, 'export')
    FileUtils.rm_rf(export_dir)

    cmd = [
      'docker', 'run', '--rm',
      '-v', "#{work_dir}:/work",
      'ghcr.io/ecosyste-ms/maven-index-exporter'
    ]

    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      Rails.logger.error "Docker export failed: #{stderr}"
      raise "Docker export failed: #{stderr}"
    end

    Rails.logger.info "Docker export completed: #{stdout}"

    # Find the .fld file in the export directory
    fld_files = Dir.glob(File.join(export_dir, '*.fld')).sort
    raise "No .fld file found in export directory" if fld_files.empty?

    fld_files.first
  end

  def parse_index(fld_file)
    Rails.logger.info "Parsing index file: #{fld_file}"
    MavenIndexParser.parse(fld_file)
  end

  def save_packages(packages_data)
    Rails.logger.info "Saving #{packages_data.keys.count} packages"

    index_run_id = SecureRandom.uuid

    Repository.transaction do
      packages_data.each do |package_name, data|
        package = repository.packages.find_or_initialize_by(name: package_name)
        package.group_id = data[:group_id]
        package.artifact_id = data[:artifact_id]
        package.last_modified = data[:last_modified]
        package.index_run_id = index_run_id
        package.save!

        data[:versions].each do |version_data|
          version = package.versions.find_or_initialize_by(number: version_data[:number])
          version.packaging = version_data[:packaging]
          version.last_modified = version_data[:last_modified]
          version.index_run_id = index_run_id
          version.save!
        end

        package.versions
               .where('versions.index_run_id IS DISTINCT FROM ?', index_run_id)
               .delete_all
      end

      stale_packages = repository.packages
                                     .where('packages.index_run_id IS DISTINCT FROM ?', index_run_id)
      Version.where(package_id: stale_packages.select(:id)).delete_all
      stale_packages.delete_all
    end
  end

  def cleanup_files(work_dir)
    return unless work_dir && Dir.exist?(work_dir)

    expanded_work_dir = validate_work_directory!(work_dir)

    retention_days = ENV.fetch('INDEX_RETENTION_DAYS', 7).to_i
    cutoff_time = retention_days.days.ago

    # Only delete if files are older than retention period
    if File.mtime(expanded_work_dir) < cutoff_time
      FileUtils.rm_rf(expanded_work_dir)
      Rails.logger.info "Cleaned up work directory: #{expanded_work_dir}"
    end
  end

  def keep_files?
    ENV['KEEP_INDEX_FILES'] == 'true'
  end

  def work_root
    Rails.root.join('tmp', 'maven-indexes').expand_path
  end

  def validate_work_directory!(work_dir)
    expanded_work_dir = Pathname.new(work_dir).expand_path
    raise "Unsafe work directory: #{expanded_work_dir}" unless expanded_work_dir.dirname == work_root

    expanded_work_dir
  end

  def download_response(url, redirects_remaining = MAX_REDIRECTS)
    uri = validate_download_uri!(url)
    connection = Faraday.new do |faraday|
      faraday.request :retry, max: 2, interval: 0.5
      faraday.adapter Faraday.default_adapter
    end

    response = connection.get(uri.to_s) do |request|
      request.options.timeout = 300
    end
    return response unless REDIRECT_STATUSES.include?(response.status)

    raise 'Too many redirects while downloading index' if redirects_remaining.zero?

    location = response.headers['location']
    raise 'Index redirect did not include a location' if location.blank?

    download_response(URI.join(uri.to_s, location).to_s, redirects_remaining - 1)
  rescue URI::InvalidURIError
    raise "Invalid index URL: #{url}"
  end

  def validate_download_uri!(url)
    uri = URI.parse(url)
    unless %w[http https].include?(uri.scheme) && uri.hostname.present? && uri.userinfo.blank?
      raise "Invalid index URL: #{url}"
    end

    if Repository.blocked_hostname?(uri.hostname)
      raise "Index URL uses a blocked host: #{uri.hostname}"
    end

    addresses = resolved_ip_addresses(uri.hostname)
    if addresses.empty? || addresses.any? { |address| Repository.blocked_address?(address) }
      raise "Index URL resolves to a blocked address: #{uri.hostname}"
    end

    uri
  end

  def resolved_ip_addresses(hostname)
    Addrinfo.getaddrinfo(hostname, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
            .map(&:ip_address)
            .uniq
  rescue SocketError => e
    raise "Failed to resolve index host #{hostname}: #{e.message}"
  end
end
