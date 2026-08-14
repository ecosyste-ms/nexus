require 'csv'
require 'json'
require 'securerandom'
require 'time'

class NexusIndexImporter
  class ProtocolError < StandardError; end

  MODES = %w[current full incremental].freeze
  EVENT_TYPES = %w[add remove].freeze
  CURSOR_KEYS = %w[index_id chain_id last_incremental timestamp etag last_modified].freeze
  MAX_COORDINATE_LENGTH = 255

  attr_reader :repository, :connection, :mode, :index_run_id, :checkpoint_count

  def initialize(repository)
    @repository = repository
    @connection = ApplicationRecord.connection
    @stage_table = "nexus_index_events_#{SecureRandom.hex(8)}"
    @checkpoint_count = 0
  end

  def call(stream)
    control = read_record(stream)
    raise ProtocolError, 'nexus did not emit a sync record' unless control

    read_control(control)
    return import_current(stream) if mode == 'current'

    @index_run_id = mode == 'full' ? SecureRandom.uuid : repository.index_run_id
    if index_run_id.blank?
      raise ProtocolError, 'incremental sync requires an existing full index run'
    end

    create_stage_table
    first_record = read_record(stream)
    while first_record
      if mode == 'full' && checkpoint_count.positive?
        raise ProtocolError, 'full sync emitted more than one chunk'
      end

      import_chunk(stream, first_record)
      @checkpoint_count += 1
      first_record = read_record(stream)
    end

    raise ProtocolError, "#{mode} sync did not emit a checkpoint" if checkpoint_count.zero?

    { mode: mode, checkpoint_count: checkpoint_count }
  ensure
    drop_stage_table if @stage_table_created
  end

  def import_current(stream)
    extra_record = read_record(stream)
    raise ProtocolError, "current sync emitted #{extra_record['type']} record" if extra_record

    { mode: mode, checkpoint_count: 0 }
  end

  def read_control(record)
    unless record['type'] == 'sync' && MODES.include?(record['mode'])
      raise ProtocolError, 'first nexus record must describe the sync mode'
    end

    validate_required_string(record, 'index_id')
    validate_optional_integer(record, 'from')
    validate_optional_integer(record, 'to')

    @mode = record['mode']
    @index_id = record['index_id']
  end

  def import_chunk(stream, first_record)
    cursor = nil

    ApplicationRecord.transaction(requires_new: true) do
      connection.execute('SET LOCAL statement_timeout = 0')
      connection.execute("TRUNCATE TABLE #{quoted_stage_table}")
      cursor = copy_chunk(stream, first_record)

      if mode == 'full'
        merge_full_artifacts
        refresh_full_catalog
      else
        merge_incremental_artifacts
        refresh_incremental_catalog
      end

      persist_cursor(cursor)
    end

    cursor
  end

  def copy_chunk(stream, first_record)
    cursor = nil
    sequence = 0
    record = first_record
    copy_sql = <<~SQL.squish
      COPY #{quoted_stage_table}
        (sequence, operation, group_id, artifact_id, version, classifier, extension, packaging, last_modified)
      FROM STDIN WITH (FORMAT csv)
    SQL

    connection.raw_connection.copy_data(copy_sql) do
      loop do
        case record['type']
        when *EVENT_TYPES
          sequence += 1
          connection.raw_connection.put_copy_data(stage_row(record, sequence))
        when 'checkpoint'
          cursor = validate_cursor(record['cursor'])
          break
        else
          raise ProtocolError, "unexpected nexus record type: #{record['type'].inspect}"
        end

        record = read_record(stream)
        raise ProtocolError, 'nexus chunk ended before its checkpoint' unless record
      end
    end

    cursor
  end

  def stage_row(record, sequence)
    group_id = validate_coordinate(record, 'group_id')
    artifact_id = validate_coordinate(record, 'artifact_id')
    version = validate_coordinate(record, 'version')
    classifier = validate_coordinate(record, 'classifier', optional: true)
    extension = validate_coordinate(record, 'extension', optional: true)
    packaging = validate_coordinate(record, 'packaging', optional: true, nullable: true)

    if "#{group_id}:#{artifact_id}".length > MAX_COORDINATE_LENGTH
      raise ProtocolError, 'package name exceeds the database limit'
    end

    last_modified = parse_time(record['modified_at'] || record['file_modified'])

    CSV.generate_line([
      sequence,
      record['type'],
      group_id,
      artifact_id,
      version,
      classifier,
      extension,
      packaging,
      last_modified&.iso8601(6)
    ])
  end

  def validate_coordinate(record, key, optional: false, nullable: false)
    value = record[key]
    return nil if nullable && value.nil?
    return '' if optional && value.nil?

    unless value.is_a?(String) && (optional || value.present?)
      raise ProtocolError, "nexus #{key} must be a#{optional ? 'n optional' : ''} string"
    end
    raise ProtocolError, "nexus #{key} exceeds the database limit" if value.length > MAX_COORDINATE_LENGTH

    value
  end

  def parse_time(value)
    return if value.nil?
    raise ProtocolError, 'nexus timestamp must be a string' unless value.is_a?(String)

    Time.iso8601(value).utc
  rescue ArgumentError
    raise ProtocolError, "invalid nexus timestamp: #{value.inspect}"
  end

  def validate_cursor(value)
    raise ProtocolError, 'nexus checkpoint cursor must be an object' unless value.is_a?(Hash)

    cursor = value.slice(*CURSOR_KEYS)
    validate_required_string(cursor, 'index_id')
    validate_required_string(cursor, 'timestamp')
    validate_optional_string(cursor, 'chain_id')
    validate_optional_string(cursor, 'etag')
    validate_optional_string(cursor, 'last_modified')
    validate_optional_integer(cursor, 'last_incremental')
    parse_time(cursor['timestamp'])

    unless cursor['index_id'] == @index_id
      raise ProtocolError, 'nexus checkpoint index ID does not match the sync record'
    end
    if mode == 'incremental' && cursor['last_incremental'].nil?
      raise ProtocolError, 'incremental checkpoint is missing its counter'
    end

    cursor
  end

  def validate_required_string(record, key)
    value = record[key]
    raise ProtocolError, "nexus #{key} must be a non-empty string" unless value.is_a?(String) && value.present?
  end

  def validate_optional_string(record, key)
    value = record[key]
    raise ProtocolError, "nexus #{key} must be a string" unless value.nil? || value.is_a?(String)
  end

  def validate_optional_integer(record, key)
    value = record[key]
    unless value.nil? || (value.is_a?(Integer) && value >= 0)
      raise ProtocolError, "nexus #{key} must be a non-negative integer"
    end
  end

  def read_record(stream)
    line = stream.gets
    return unless line

    record = JSON.parse(line, max_nesting: 20)
    raise ProtocolError, 'nexus record must be a JSON object' unless record.is_a?(Hash)

    record
  rescue JSON::ParserError => e
    raise ProtocolError, "invalid nexus JSON: #{e.message}"
  end

  def create_stage_table
    connection.execute(<<~SQL)
      CREATE TEMPORARY TABLE #{quoted_stage_table} (
        sequence bigint NOT NULL,
        operation text NOT NULL,
        group_id text NOT NULL,
        artifact_id text NOT NULL,
        version text NOT NULL,
        classifier text NOT NULL,
        extension text NOT NULL,
        packaging text,
        last_modified timestamptz
      ) ON COMMIT DELETE ROWS
    SQL
    @stage_table_created = true
  end

  def drop_stage_table
    connection.execute("DROP TABLE IF EXISTS #{quoted_stage_table}")
    @stage_table_created = false
  end

  def quoted_stage_table
    connection.quote_table_name(@stage_table)
  end

  def latest_events_cte
    <<~SQL
      ranked_events AS (
        SELECT *,
               row_number() OVER (
                 PARTITION BY group_id, artifact_id, version, classifier, extension
                 ORDER BY sequence DESC
               ) AS event_rank
        FROM #{quoted_stage_table}
      ),
      latest_events AS (
        SELECT *
        FROM ranked_events
        WHERE event_rank = 1
      ),
      surviving_additions AS (
        SELECT additions.*
        FROM latest_events additions
        WHERE additions.operation = 'add'
          AND NOT EXISTS (
            SELECT 1
            FROM #{quoted_stage_table} removals
            WHERE removals.operation = 'remove'
              AND removals.extension = ''
              AND removals.group_id = additions.group_id
              AND removals.artifact_id = additions.artifact_id
              AND removals.version = additions.version
              AND removals.classifier = additions.classifier
              AND removals.sequence > additions.sequence
          )
      )
    SQL
  end

  def merge_full_artifacts
    connection.execute(<<~SQL)
      WITH #{latest_events_cte}
      INSERT INTO maven_artifacts
        (repository_id, group_id, artifact_id, version, classifier, extension, packaging, last_modified, index_run_id)
      SELECT #{quoted_repository_id}, group_id, artifact_id, version, classifier, extension,
             packaging, last_modified, #{quoted_index_run_id}
      FROM surviving_additions
      ON CONFLICT (repository_id, group_id, artifact_id, version, classifier, extension)
      DO UPDATE SET
        packaging = EXCLUDED.packaging,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id
    SQL

    connection.execute(<<~SQL)
      DELETE FROM maven_artifacts
      WHERE repository_id = #{quoted_repository_id}
        AND index_run_id IS DISTINCT FROM #{quoted_index_run_id}
    SQL
  end

  def merge_incremental_artifacts
    connection.execute(<<~SQL)
      WITH #{latest_events_cte}
      DELETE FROM maven_artifacts artifacts
      USING latest_events events
      WHERE events.operation = 'remove'
        AND artifacts.repository_id = #{quoted_repository_id}
        AND artifacts.group_id = events.group_id
        AND artifacts.artifact_id = events.artifact_id
        AND artifacts.version = events.version
        AND artifacts.classifier = events.classifier
        AND artifacts.extension = events.extension
    SQL

    connection.execute(<<~SQL)
      DELETE FROM maven_artifacts artifacts
      USING #{quoted_stage_table} removals
      WHERE removals.operation = 'remove'
        AND removals.extension = ''
        AND artifacts.repository_id = #{quoted_repository_id}
        AND artifacts.group_id = removals.group_id
        AND artifacts.artifact_id = removals.artifact_id
        AND artifacts.version = removals.version
        AND artifacts.classifier = removals.classifier
        AND NOT EXISTS (
          SELECT 1
          FROM #{quoted_stage_table} later_additions
          WHERE later_additions.operation = 'add'
            AND later_additions.group_id = artifacts.group_id
            AND later_additions.artifact_id = artifacts.artifact_id
            AND later_additions.version = artifacts.version
            AND later_additions.classifier = artifacts.classifier
            AND later_additions.extension = artifacts.extension
            AND later_additions.sequence > removals.sequence
        )
    SQL

    connection.execute(<<~SQL)
      WITH #{latest_events_cte}
      INSERT INTO maven_artifacts
        (repository_id, group_id, artifact_id, version, classifier, extension, packaging, last_modified, index_run_id)
      SELECT #{quoted_repository_id}, group_id, artifact_id, version, classifier, extension,
             packaging, last_modified, #{quoted_index_run_id}
      FROM surviving_additions
      ON CONFLICT (repository_id, group_id, artifact_id, version, classifier, extension)
      DO UPDATE SET
        packaging = EXCLUDED.packaging,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id
    SQL
  end

  def refresh_full_catalog
    connection.execute(<<~SQL)
      INSERT INTO packages
        (repository_id, name, group_id, artifact_id, last_modified, index_run_id, created_at, updated_at)
      SELECT #{quoted_repository_id}, group_id || ':' || artifact_id, group_id, artifact_id,
             MAX(last_modified), #{quoted_index_run_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM maven_artifacts
      WHERE repository_id = #{quoted_repository_id}
      GROUP BY group_id, artifact_id
      ON CONFLICT (repository_id, name)
      DO UPDATE SET
        group_id = EXCLUDED.group_id,
        artifact_id = EXCLUDED.artifact_id,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id,
        updated_at = CURRENT_TIMESTAMP
    SQL

    connection.execute(<<~SQL)
      INSERT INTO versions
        (package_id, number, packaging, last_modified, index_run_id, created_at, updated_at)
      SELECT packages.id, artifacts.version,
             (array_agg(
               artifacts.packaging
               ORDER BY (artifacts.classifier = '') DESC,
                        (artifacts.extension <> 'pom') DESC,
                        artifacts.last_modified DESC NULLS LAST
             ) FILTER (WHERE artifacts.packaging IS NOT NULL))[1],
             MAX(artifacts.last_modified),
             #{quoted_index_run_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM maven_artifacts artifacts
      INNER JOIN packages
        ON packages.repository_id = artifacts.repository_id
       AND packages.group_id = artifacts.group_id
       AND packages.artifact_id = artifacts.artifact_id
      WHERE artifacts.repository_id = #{quoted_repository_id}
      GROUP BY packages.id, artifacts.version
      ON CONFLICT (package_id, number)
      DO UPDATE SET
        packaging = EXCLUDED.packaging,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id,
        updated_at = CURRENT_TIMESTAMP
    SQL

    connection.execute(<<~SQL)
      DELETE FROM versions
      USING packages
      WHERE versions.package_id = packages.id
        AND packages.repository_id = #{quoted_repository_id}
        AND versions.index_run_id IS DISTINCT FROM #{quoted_index_run_id}
    SQL

    connection.execute(<<~SQL)
      DELETE FROM packages
      WHERE repository_id = #{quoted_repository_id}
        AND index_run_id IS DISTINCT FROM #{quoted_index_run_id}
    SQL
  end

  def refresh_incremental_catalog
    connection.execute(<<~SQL)
      WITH affected_packages AS (
        SELECT DISTINCT group_id, artifact_id
        FROM #{quoted_stage_table}
      ),
      package_rows AS (
        SELECT artifacts.group_id, artifacts.artifact_id, MAX(artifacts.last_modified) AS last_modified
        FROM maven_artifacts artifacts
        INNER JOIN affected_packages
          ON affected_packages.group_id = artifacts.group_id
         AND affected_packages.artifact_id = artifacts.artifact_id
        WHERE artifacts.repository_id = #{quoted_repository_id}
        GROUP BY artifacts.group_id, artifacts.artifact_id
      )
      INSERT INTO packages
        (repository_id, name, group_id, artifact_id, last_modified, index_run_id, created_at, updated_at)
      SELECT #{quoted_repository_id}, group_id || ':' || artifact_id, group_id, artifact_id,
             last_modified, #{quoted_index_run_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM package_rows
      ON CONFLICT (repository_id, name)
      DO UPDATE SET
        group_id = EXCLUDED.group_id,
        artifact_id = EXCLUDED.artifact_id,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id,
        updated_at = CURRENT_TIMESTAMP
    SQL

    connection.execute(<<~SQL)
      WITH affected_versions AS (
        SELECT DISTINCT group_id, artifact_id, version
        FROM #{quoted_stage_table}
      )
      DELETE FROM versions
      USING packages, affected_versions
      WHERE versions.package_id = packages.id
        AND packages.repository_id = #{quoted_repository_id}
        AND packages.group_id = affected_versions.group_id
        AND packages.artifact_id = affected_versions.artifact_id
        AND versions.number = affected_versions.version
        AND NOT EXISTS (
          SELECT 1
          FROM maven_artifacts artifacts
          WHERE artifacts.repository_id = #{quoted_repository_id}
            AND artifacts.group_id = affected_versions.group_id
            AND artifacts.artifact_id = affected_versions.artifact_id
            AND artifacts.version = affected_versions.version
        )
    SQL

    connection.execute(<<~SQL)
      WITH affected_versions AS (
        SELECT DISTINCT group_id, artifact_id, version
        FROM #{quoted_stage_table}
      ),
      version_rows AS (
        SELECT artifacts.group_id, artifacts.artifact_id, artifacts.version,
               (array_agg(
                 artifacts.packaging
                 ORDER BY (artifacts.classifier = '') DESC,
                          (artifacts.extension <> 'pom') DESC,
                          artifacts.last_modified DESC NULLS LAST
               ) FILTER (WHERE artifacts.packaging IS NOT NULL))[1] AS packaging,
               MAX(artifacts.last_modified) AS last_modified
        FROM maven_artifacts artifacts
        INNER JOIN affected_versions
          ON affected_versions.group_id = artifacts.group_id
         AND affected_versions.artifact_id = artifacts.artifact_id
         AND affected_versions.version = artifacts.version
        WHERE artifacts.repository_id = #{quoted_repository_id}
        GROUP BY artifacts.group_id, artifacts.artifact_id, artifacts.version
      )
      INSERT INTO versions
        (package_id, number, packaging, last_modified, index_run_id, created_at, updated_at)
      SELECT packages.id, version_rows.version, version_rows.packaging, version_rows.last_modified,
             #{quoted_index_run_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM version_rows
      INNER JOIN packages
        ON packages.repository_id = #{quoted_repository_id}
       AND packages.group_id = version_rows.group_id
       AND packages.artifact_id = version_rows.artifact_id
      ON CONFLICT (package_id, number)
      DO UPDATE SET
        packaging = EXCLUDED.packaging,
        last_modified = EXCLUDED.last_modified,
        index_run_id = EXCLUDED.index_run_id,
        updated_at = CURRENT_TIMESTAMP
    SQL

    connection.execute(<<~SQL)
      WITH affected_packages AS (
        SELECT DISTINCT group_id, artifact_id
        FROM #{quoted_stage_table}
      )
      DELETE FROM packages
      USING affected_packages
      WHERE packages.repository_id = #{quoted_repository_id}
        AND packages.group_id = affected_packages.group_id
        AND packages.artifact_id = affected_packages.artifact_id
        AND NOT EXISTS (
          SELECT 1
          FROM maven_artifacts artifacts
          WHERE artifacts.repository_id = #{quoted_repository_id}
            AND artifacts.group_id = affected_packages.group_id
            AND artifacts.artifact_id = affected_packages.artifact_id
        )
    SQL
  end

  def persist_cursor(cursor)
    repository.update!(
      metadata: repository.metadata.to_h.merge('nexus_cursor' => cursor),
      index_timestamp: cursor['timestamp'],
      index_chain_id: cursor['chain_id'],
      last_incremental_chunk: cursor['last_incremental'],
      index_run_id: index_run_id
    )
  end

  def quoted_repository_id
    connection.quote(repository.id)
  end

  def quoted_index_run_id
    connection.quote(index_run_id)
  end
end
