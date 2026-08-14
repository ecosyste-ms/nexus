require 'rbconfig'
require 'test_helper'

class IndexRepositoryServiceTest < ActiveSupport::TestCase
  setup do
    @repository = Repository.create!(
      name: 'test-repo',
      url: 'https://repo.example.com/releases'
    )
    @service = IndexRepositoryService.new(@repository)
  end

  test 'builds a sync command with the repository URL' do
    assert_equal [
      'nexus',
      'sync',
      'https://repo.example.com/releases'
    ], @service.nexus_command
  end

  test 'passes an existing cursor and the private address opt-out' do
    previous_allow_private = ENV['NEXUS_ALLOW_PRIVATE']
    ENV['NEXUS_ALLOW_PRIVATE'] = 'true'

    assert_equal [
      'nexus',
      'sync',
      '--allow-private',
      '--cursor',
      '/tmp/cursor.json',
      'https://repo.example.com/releases'
    ], @service.nexus_command('/tmp/cursor.json')
  ensure
    if previous_allow_private
      ENV['NEXUS_ALLOW_PRIVATE'] = previous_allow_private
    else
      ENV.delete('NEXUS_ALLOW_PRIVATE')
    end
  end

  test 'writes the stored cursor to a mode 0600 temporary file' do
    cursor = {
      'index_id' => 'test-index',
      'timestamp' => '2026-08-14T10:00:00Z'
    }
    @repository.update!(metadata: { 'nexus_cursor' => cursor })
    path = nil

    @service.with_cursor_file do |cursor_path|
      path = cursor_path
      assert_equal cursor, JSON.parse(File.read(cursor_path))
      assert_equal 0o600, File.stat(cursor_path).mode & 0o777
    end

    assert_not File.exist?(path)
  end

  test 'streams nexus output into the importer' do
    output = [
      { type: 'sync', mode: 'full', index_id: 'test-index' },
      {
        type: 'add', group_id: 'org.example', artifact_id: 'library',
        version: '1.0.0', extension: 'jar', packaging: 'jar'
      },
      {
        type: 'checkpoint',
        cursor: {
          index_id: 'test-index', timestamp: '2026-08-14T10:00:00Z'
        }
      }
    ].map(&:to_json).join("\n")

    Tempfile.create(['fake-nexus-', '.rb']) do |script|
      script.write("STDOUT.write(#{(output + "\n").dump})\n")
      script.flush

      result = @service.run_nexus_process([RbConfig.ruby, script.path])

      assert_equal 'full', result[:mode]
      assert_equal ['org.example:library'], @repository.packages.pluck(:name)
    end
  end

  test 'reports bounded nexus diagnostics on command failure' do
    Tempfile.create(['fake-nexus-', '.rb']) do |script|
      script.write("STDERR.write('repository index is unavailable')\nexit 1\n")
      script.flush

      error = assert_raises(IndexRepositoryService::NexusCommandError) do
        @service.run_nexus_process([RbConfig.ruby, script.path])
      end

      assert_match(/repository index is unavailable/, error.message)
    end
  end

  test 'marks the repository completed after a successful sync' do
    package = @repository.packages.create!(
      name: 'org.example:library',
      group_id: 'org.example',
      artifact_id: 'library'
    )
    package.versions.create!(number: '1.0.0')
    @service.expects(:run_nexus).returns(mode: 'current', checkpoint_count: 0)

    result = @service.call

    assert result[:success]
    assert_equal 1, result[:package_count]
    assert_equal 'completed', @repository.reload.status
    assert_not_nil @repository.last_indexed_at
  end

  test 'marks the repository failed after a sync error' do
    @service.expects(:run_nexus).raises(IndexRepositoryService::NexusCommandError, 'sync failed')

    assert_raises(IndexRepositoryService::NexusCommandError) { @service.call }

    assert_equal 'failed', @repository.reload.status
    assert_equal 'sync failed', @repository.error_message
  end
end
