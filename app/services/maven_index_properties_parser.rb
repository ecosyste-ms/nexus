class MavenIndexPropertiesParser
  def self.parse(properties_content)
    properties = {}

    properties_content.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      properties[key.strip] = value.strip if key && value
    end

    {
      timestamp: properties['nexus.index.timestamp'],
      chain_id: properties['nexus.index.chain-id'],
      last_incremental: properties['nexus.index.last-incremental']&.to_i,
      incremental_chunks: extract_incremental_chunks(properties)
    }
  end

  private

  def self.extract_incremental_chunks(properties)
    chunks = []
    properties.each do |key, value|
      if key =~ /^nexus\.index\.incremental-(\d+)$/
        chunks << value.to_i
      end
    end
    chunks.sort
  end
end
