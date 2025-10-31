class MavenIndexParser
  attr_reader :file_path

  def initialize(file_path)
    @file_path = file_path
  end

  def parse
    packages = {}
    current_doc = nil
    reading_uinfo = false

    File.readlines(file_path).each do |line|
      line = line.strip

      if line.start_with?("doc ")
        current_doc = line.split[1].to_i
      elsif line == "name u"
        reading_uinfo = true
      elsif reading_uinfo && line.start_with?("value ")
        value = line.sub("value ", "")
        parts = value.split("|")

        next if parts.length < 5

        group_id = parts[0]
        artifact_id = parts[1]
        version = parts[2]
        packaging = parts[4]

        package_name = "#{group_id}:#{artifact_id}"

        packages[package_name] ||= {
          group_id: group_id,
          artifact_id: artifact_id,
          versions: []
        }

        packages[package_name][:versions] << {
          number: version,
          packaging: packaging
        }

        reading_uinfo = false
      end
    end

    packages
  end

  def self.parse(file_path)
    new(file_path).parse
  end
end
