require 'test_helper'

class NexusIndexImporterTest < ActiveSupport::TestCase
  setup do
    @repository = Repository.create!(
      name: 'central',
      url: 'https://repo1.maven.org/maven2'
    )
  end

  test 'imports a full snapshot and removes stale catalog rows' do
    stale_package = @repository.packages.create!(
      name: 'org.example:stale',
      group_id: 'org.example',
      artifact_id: 'stale',
      index_run_id: '26de7823-1538-4d5f-aa2a-8ea84e85d738'
    )
    stale_package.versions.create!(
      number: '1.0.0',
      index_run_id: '26de7823-1538-4d5f-aa2a-8ea84e85d738'
    )

    result = importer.call(stream(
      sync_record('full', to: 1),
      add_record(version: '1.0.0', extension: 'jar', packaging: 'jar'),
      add_record(version: '1.0.0', classifier: 'sources', extension: 'jar', packaging: 'java-source'),
      add_record(version: '2.0.0', extension: 'pom', packaging: 'pom'),
      add_record(artifact_id: 'removed', extension: 'jar'),
      remove_record(artifact_id: 'removed', extension: 'jar'),
      checkpoint_record(1)
    ))

    assert_equal({ mode: 'full', checkpoint_count: 1 }, result)
    assert_equal 3, @repository.maven_artifacts.count
    assert_equal ['org.example:library'], @repository.packages.pluck(:name)
    assert_equal ['1.0.0', '2.0.0'], @repository.packages.first.versions.order(:number).pluck(:number)
    assert_equal 'jar', @repository.packages.first.versions.find_by!(number: '1.0.0').packaging
    assert_not Package.exists?(stale_package.id)

    @repository.reload
    assert_equal 1, @repository.last_incremental_chunk
    assert_equal 'chain-1', @repository.index_chain_id
    assert_equal 'central-index', @repository.nexus_cursor['index_id']
    assert @repository.index_run_id.present?
  end

  test 'rolls back a chunk that ends without a checkpoint' do
    error = assert_raises(NexusIndexImporter::ProtocolError) do
      importer.call(stream(
        sync_record('full', to: 1),
        add_record(extension: 'jar')
      ))
    end

    assert_match(/before its checkpoint/, error.message)
    assert_equal 0, @repository.maven_artifacts.count
    assert_equal 0, @repository.packages.count
    assert_nil @repository.reload.nexus_cursor
  end

  test 'tracks variants so removing one classifier keeps the version' do
    importer.call(stream(
      sync_record('full', to: 1),
      add_record(extension: 'jar'),
      add_record(classifier: 'sources', extension: 'jar'),
      checkpoint_record(1)
    ))

    importer.call(stream(
      sync_record('incremental', from: 1, to: 2),
      remove_record(classifier: 'sources', extension: 'jar'),
      checkpoint_record(2)
    ))

    assert_equal 1, @repository.maven_artifacts.count
    assert_equal ['1.0.0'], @repository.packages.first.versions.pluck(:number)

    importer.call(stream(
      sync_record('incremental', from: 2, to: 3),
      remove_record(extension: 'jar'),
      checkpoint_record(3)
    ))

    assert_equal 0, @repository.maven_artifacts.count
    assert_equal 0, @repository.packages.count
    assert_equal 0, Version.for_repository(@repository.name).count
  end

  test 'applies a removal without an extension to all matching variants' do
    importer.call(stream(
      sync_record('full', to: 1),
      add_record(extension: 'jar'),
      add_record(extension: 'pom'),
      checkpoint_record(1)
    ))

    importer.call(stream(
      sync_record('incremental', from: 1, to: 2),
      remove_record,
      checkpoint_record(2)
    ))

    assert_equal 0, @repository.maven_artifacts.count
    assert_equal 0, @repository.packages.count
  end

  test 'keeps committed checkpoints when a later incremental chunk fails' do
    importer.call(stream(
      sync_record('full', to: 1),
      add_record(extension: 'jar'),
      checkpoint_record(1)
    ))

    assert_raises(NexusIndexImporter::ProtocolError) do
      importer.call(stream(
        sync_record('incremental', from: 1, to: 3),
        add_record(version: '2.0.0', extension: 'jar'),
        checkpoint_record(2),
        add_record(version: '3.0.0', extension: 'jar')
      ))
    end

    assert_equal 2, @repository.reload.last_incremental_chunk
    assert_equal ['1.0.0', '2.0.0'], @repository.packages.first.versions.order(:number).pluck(:number)
  end

  test 'accepts a current sync without changing its cursor' do
    importer.call(stream(
      sync_record('full', to: 1),
      add_record(extension: 'jar'),
      checkpoint_record(1)
    ))
    cursor = @repository.reload.nexus_cursor

    result = importer.call(stream(sync_record('current', from: 1, to: 1)))

    assert_equal({ mode: 'current', checkpoint_count: 0 }, result)
    assert_equal cursor, @repository.reload.nexus_cursor
  end

  def importer
    NexusIndexImporter.new(@repository)
  end

  def stream(*records)
    StringIO.new(records.map(&:to_json).join("\n") + "\n")
  end

  def sync_record(mode, from: nil, to: nil)
    {
      type: 'sync',
      mode: mode,
      index_id: 'central-index',
      from: from,
      to: to
    }.compact
  end

  def add_record(artifact_id: 'library', version: '1.0.0', classifier: nil, extension: nil, packaging: nil)
    {
      type: 'add',
      group_id: 'org.example',
      artifact_id: artifact_id,
      version: version,
      classifier: classifier,
      extension: extension,
      packaging: packaging,
      modified_at: '2026-08-14T10:00:00Z'
    }.compact
  end

  def remove_record(artifact_id: 'library', version: '1.0.0', classifier: nil, extension: nil)
    {
      type: 'remove',
      group_id: 'org.example',
      artifact_id: artifact_id,
      version: version,
      classifier: classifier,
      extension: extension
    }.compact
  end

  def checkpoint_record(counter)
    {
      type: 'checkpoint',
      cursor: {
        index_id: 'central-index',
        chain_id: 'chain-1',
        last_incremental: counter,
        timestamp: "2026-08-14T10:00:0#{counter}Z",
        etag: %Q{"etag-#{counter}"},
        last_modified: 'Fri, 14 Aug 2026 10:00:00 GMT'
      }
    }
  end
end
