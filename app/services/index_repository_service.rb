require 'open3'
require 'fileutils'

class IndexRepositoryService
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
    save_packages(packages_data)

    repository.mark_as_completed!(
      package_count: packages_data.keys.count,
      index_size: File.size(gz_file)
    )

    cleanup_files(work_dir) unless keep_files?

    { success: true, package_count: packages_data.keys.count }
  rescue StandardError => e
    repository.mark_as_failed!(e)
    cleanup_files(work_dir) if work_dir && Dir.exist?(work_dir)
    raise
  end

  private

  def create_work_directory
    dir = Rails.root.join('tmp', 'maven-indexes', repository.name)
    FileUtils.mkdir_p(dir)
    dir.to_s
  end

  def download_index(work_dir)
    gz_file = File.join(work_dir, 'nexus-maven-repository-index.gz')
    url = repository.index_url

    Rails.logger.info "Downloading index from #{url}"

    conn = Faraday.new do |f|
      f.request :retry, max: 2, interval: 0.5
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
    end

    response = conn.get(url) do |req|
      req.options.timeout = 300
    end

    raise "Failed to download index: #{response.status}" unless response.status == 200

    File.open(gz_file, 'wb') { |f| f.write(response.body) }
    gz_file
  end

  def export_index(work_dir, gz_file)
    Rails.logger.info "Exporting index using Docker"

    # Don't pre-create export directory - Docker script checks for it and skips if exists
    # gz_file is already in the correct location (work_dir/nexus-maven-repository-index.gz)
    # Docker expects this file at /work/nexus-maven-repository-index.gz

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
    export_dir = File.join(work_dir, 'export')
    fld_files = Dir.glob(File.join(export_dir, '*.fld'))
    raise "No .fld file found in export directory" if fld_files.empty?

    fld_files.first
  end

  def parse_index(fld_file)
    Rails.logger.info "Parsing index file: #{fld_file}"
    MavenIndexParser.parse(fld_file)
  end

  def save_packages(packages_data)
    Rails.logger.info "Saving #{packages_data.keys.count} packages"

    packages_data.each do |package_name, data|
      package = repository.packages.find_or_initialize_by(name: package_name)
      package.group_id = data[:group_id]
      package.artifact_id = data[:artifact_id]
      package.last_modified = Time.current
      package.save!

      data[:versions].each do |version_data|
        version = package.versions.find_or_initialize_by(number: version_data[:number])
        version.packaging = version_data[:packaging]
        version.last_modified = Time.current
        version.save!
      end
    end
  end

  def cleanup_files(work_dir)
    return unless work_dir && Dir.exist?(work_dir)

    retention_days = ENV.fetch('INDEX_RETENTION_DAYS', 7).to_i
    cutoff_time = retention_days.days.ago

    # Only delete if files are older than retention period
    if File.mtime(work_dir) < cutoff_time
      FileUtils.rm_rf(work_dir)
      Rails.logger.info "Cleaned up work directory: #{work_dir}"
    end
  end

  def keep_files?
    ENV['KEEP_INDEX_FILES'] == 'true'
  end
end
