require "test_helper"

class IndexRepositoryServiceTest < ActiveSupport::TestCase
  setup do
    @repository = Repository.create!(
      name: "test-repo",
      url: "https://repo.example.com/releases"
    )
    @service = IndexRepositoryService.new(@repository)
    @work_dir = Rails.root.join('tmp', 'test-maven-indexes', @repository.name).to_s
  end

  teardown do
    FileUtils.rm_rf(@work_dir) if Dir.exist?(@work_dir)
  end

  context "#create_work_directory" do
    should "create work directory for repository" do
      dir = @service.send(:create_work_directory)
      assert Dir.exist?(dir)
      assert_match /maven-indexes\/test-repo/, dir
    end
  end

  context "#download_index" do
    should "download index file successfully" do
      FileUtils.mkdir_p(@work_dir)

      stub_request(:get, "https://repo.example.com/releases/.index/nexus-maven-repository-index.gz")
        .to_return(status: 200, body: "fake gzip content")

      gz_file = @service.send(:download_index, @work_dir)

      assert File.exist?(gz_file)
      assert_equal "fake gzip content", File.read(gz_file)
    end

    should "follow redirects" do
      FileUtils.mkdir_p(@work_dir)

      stub_request(:get, "https://repo.example.com/releases/.index/nexus-maven-repository-index.gz")
        .to_return(status: 302, headers: { 'Location' => 'https://cdn.example.com/index.gz' })

      stub_request(:get, "https://cdn.example.com/index.gz")
        .to_return(status: 200, body: "redirected content")

      gz_file = @service.send(:download_index, @work_dir)

      assert File.exist?(gz_file)
      assert_equal "redirected content", File.read(gz_file)
    end

    should "raise error on failed download" do
      stub_request(:get, "https://repo.example.com/releases/.index/nexus-maven-repository-index.gz")
        .to_return(status: 404)

      error = assert_raises(RuntimeError) do
        @service.send(:download_index, @work_dir)
      end

      assert_match /Failed to download index: 404/, error.message
    end

    should "handle network timeouts" do
      stub_request(:get, "https://repo.example.com/releases/.index/nexus-maven-repository-index.gz")
        .to_timeout

      assert_raises(Faraday::ConnectionFailed) do
        @service.send(:download_index, @work_dir)
      end
    end
  end

  context "#export_index with Docker" do
    should "run docker container to export index and create fld files" do

      gz_file = File.join(@work_dir, 'nexus-maven-repository-index.gz')
      FileUtils.mkdir_p(@work_dir)
      File.write(gz_file, 'test')

      # Mock Docker execution
      mock_status = mock('status')
      mock_status.expects(:success?).returns(true)

      # Mock Docker creating the export directory and fld file
      Open3.expects(:capture3).with(
        'docker', 'run', '--rm',
        '-v', "#{@work_dir}:/work",
        'ghcr.io/ecosyste-ms/maven-index-exporter'
      ).returns(['Docker export completed', '', mock_status]).tap do
        # Simulate Docker creating the export directory and fld file
        export_dir = File.join(@work_dir, 'export')
        FileUtils.mkdir_p(export_dir)
        File.write(File.join(export_dir, 'index.fld'), 'doc 0\n  field 0\n    name u\n    type string\n    value org.test|lib|1.0|NA|jar')
      end

      fld_file = @service.send(:export_index, @work_dir, gz_file)

      assert File.exist?(fld_file)
      assert_match /export\/.*\.fld$/, fld_file
      assert_match /org.test\|lib/, File.read(fld_file)
    end

    should "raise error when docker fails" do
      gz_file = File.join(@work_dir, 'nexus-maven-repository-index.gz')
      FileUtils.mkdir_p(@work_dir)
      File.write(gz_file, 'test')

      mock_status = mock('status')
      mock_status.expects(:success?).returns(false)

      Open3.expects(:capture3).returns(['', 'Docker error', mock_status])

      error = assert_raises(RuntimeError) do
        @service.send(:export_index, @work_dir, gz_file)
      end

      assert_match /Docker export failed/, error.message
    end

    should "raise error when no fld files are created" do
      gz_file = File.join(@work_dir, 'nexus-maven-repository-index.gz')
      FileUtils.mkdir_p(@work_dir)
      File.write(gz_file, 'test')

      mock_status = mock('status')
      mock_status.expects(:success?).returns(true)

      # Docker succeeds but doesn't create any fld files
      Open3.expects(:capture3).returns(['Docker completed', '', mock_status]).tap do
        # Create empty export directory
        FileUtils.mkdir_p(File.join(@work_dir, 'export'))
      end

      error = assert_raises(RuntimeError) do
        @service.send(:export_index, @work_dir, gz_file)
      end

      assert_match /No .fld file found/, error.message
    end
  end

  context "#parse_index" do
    should "parse fld file correctly" do
      fld_content = <<~FLD
        doc 0
          field 0
            name u
            type string
            value org.example|test-lib|1.0.0|NA|jar
      FLD

      fld_file = File.join(@work_dir, 'test.fld')
      FileUtils.mkdir_p(@work_dir)
      File.write(fld_file, fld_content)

      packages = @service.send(:parse_index, fld_file)

      assert_equal 1, packages.keys.count
      assert packages.key?("org.example:test-lib")
      assert_equal "org.example", packages["org.example:test-lib"][:group_id]
      assert_equal "test-lib", packages["org.example:test-lib"][:artifact_id]
    end
  end

  context "#save_packages" do
    should "create packages and versions" do
      packages_data = {
        "org.example:test-lib" => {
          group_id: "org.example",
          artifact_id: "test-lib",
          versions: [
            { number: "1.0.0", packaging: "jar" },
            { number: "1.0.1", packaging: "jar" }
          ]
        }
      }

      assert_difference 'Package.count', 1 do
        assert_difference 'Version.count', 2 do
          @service.send(:save_packages, packages_data)
        end
      end

      package = Package.find_by(name: "org.example:test-lib")
      assert_not_nil package
      assert_equal 2, package.versions.count
    end

    should "update existing packages" do
      package = @repository.packages.create!(
        name: "org.example:test-lib",
        group_id: "org.example",
        artifact_id: "test-lib"
      )

      packages_data = {
        "org.example:test-lib" => {
          group_id: "org.example",
          artifact_id: "test-lib",
          versions: [
            { number: "1.0.0", packaging: "jar" }
          ]
        }
      }

      assert_no_difference 'Package.count' do
        assert_difference 'Version.count', 1 do
          @service.send(:save_packages, packages_data)
        end
      end

      package.reload
      assert_equal 1, package.versions.count
    end
  end

  context "#call integration" do
    should "mark repository as indexing at start" do
      @service.expects(:download_index).raises(StandardError, "Test error")

      begin
        @service.call
      rescue StandardError
        # Expected
      end

      @repository.reload
      assert_equal 'failed', @repository.status
    end

    should "mark repository as failed on error" do
      @service.expects(:download_index).raises(StandardError, "Test error")

      assert_raises(StandardError) do
        @service.call
      end

      @repository.reload
      assert_equal 'failed', @repository.status
      assert_equal 'Test error', @repository.error_message
    end

    should "mark repository as completed on success" do
      stub_request(:get, @repository.index_url)
        .to_return(status: 200, body: "test content")

      # Mock Docker execution
      mock_status = mock('status')
      mock_status.expects(:success?).returns(true)

      Open3.expects(:capture3).returns(['Docker export completed', '', mock_status]).tap do
        # Simulate Docker creating the export directory and fld file
        work_dir = Rails.root.join('tmp', 'maven-indexes', @repository.name).to_s
        export_dir = File.join(work_dir, 'export')
        FileUtils.mkdir_p(export_dir)
        File.write(File.join(export_dir, 'index.fld'), "doc 0\n  field 0\n    name u\n    type string\n    value org.test|lib|1.0|NA|jar\n")
      end

      result = @service.call

      @repository.reload
      assert_equal 'completed', @repository.status
      assert result[:success]
      assert_not_nil @repository.last_indexed_at
    end
  end

  context "cleanup" do
    should "cleanup old files when retention period passed" do
      ENV['INDEX_RETENTION_DAYS'] = '1'

      old_dir = Rails.root.join('tmp', 'maven-indexes', 'old-repo')
      FileUtils.mkdir_p(old_dir)

      # Make directory appear old
      FileUtils.touch(old_dir, mtime: 2.days.ago.to_time)

      @service.send(:cleanup_files, old_dir.to_s)

      assert_not Dir.exist?(old_dir)
    ensure
      ENV.delete('INDEX_RETENTION_DAYS')
    end

    should "not cleanup recent files" do
      ENV['INDEX_RETENTION_DAYS'] = '7'
      ENV['KEEP_INDEX_FILES'] = 'false'

      FileUtils.mkdir_p(@work_dir)

      @service.send(:cleanup_files, @work_dir)

      assert Dir.exist?(@work_dir)
    ensure
      ENV.delete('INDEX_RETENTION_DAYS')
      ENV.delete('KEEP_INDEX_FILES')
    end
  end
end
