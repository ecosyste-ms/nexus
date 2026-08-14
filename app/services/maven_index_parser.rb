class MavenIndexParser
  attr_reader :file_path

  def initialize(file_path)
    @file_path = file_path
  end

  def parse
    packages = {}
    document = {}
    current_field = nil

    File.foreach(file_path) do |line|
      line = line.strip

      if line.start_with?("doc ")
        add_document(packages, document)
        document = {}
        current_field = nil
      elsif line.start_with?("name ")
        current_field = line.delete_prefix("name ")
      elsif current_field && line.start_with?("value ")
        document[current_field] = line.delete_prefix("value ")
        current_field = nil
      end
    end

    add_document(packages, document)
    packages.each_value do |package|
      package[:versions] = package.delete(:versions_by_number).values
    end

    packages
  end

  def self.parse(file_path)
    new(file_path).parse
  end

  def add_document(packages, document)
    parts = document['u'].to_s.split('|', -1)
    return if parts.length < 5

    group_id, artifact_id, version = parts[0, 3]
    return if group_id.blank? || artifact_id.blank? || version.blank?

    last_modified = parse_timestamp(document['m'])
    package_name = "#{group_id}:#{artifact_id}"
    package = packages[package_name] ||= {
      group_id: group_id,
      artifact_id: artifact_id,
      last_modified: nil,
      versions_by_number: {}
    }

    existing_version = package[:versions_by_number][version]
    if existing_version.nil? || newer_timestamp?(last_modified, existing_version[:last_modified])
      package[:versions_by_number][version] = {
        number: version,
        packaging: parts[4],
        last_modified: last_modified
      }
    end

    if last_modified && (package[:last_modified].nil? || last_modified > package[:last_modified])
      package[:last_modified] = last_modified
    end
  end

  def parse_timestamp(value)
    return if value.blank?

    milliseconds = Integer(value, 10)
    Time.at(milliseconds / 1000, (milliseconds % 1000) * 1000, :microsecond).utc
  rescue ArgumentError
    nil
  end

  def newer_timestamp?(candidate, existing)
    candidate && (existing.nil? || candidate > existing)
  end
end
