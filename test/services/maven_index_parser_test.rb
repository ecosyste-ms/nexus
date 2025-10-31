require "test_helper"

class MavenIndexParserTest < ActiveSupport::TestCase
  context "#parse" do
    setup do
      @test_file = Rails.root.join('tmp', 'test_index.fld')
      FileUtils.mkdir_p(File.dirname(@test_file))

      # Create a sample .fld file
      content = <<~FLD
        doc 0
          field 0
            name u
            type string
            value org.springframework|spring-core|5.3.0|NA|jar
          field 1
            name m
            type string
            value 1634567890000
        doc 1
          field 0
            name u
            type string
            value org.springframework|spring-core|5.3.1|NA|jar
          field 1
            name m
            type string
            value 1634567891000
        doc 2
          field 0
            name u
            type string
            value org.hibernate|hibernate-core|5.6.0|NA|jar
          field 1
            name m
            type string
            value 1634567892000
      FLD

      File.write(@test_file, content)
    end

    teardown do
      File.delete(@test_file) if File.exist?(@test_file)
    end

    should "parse .fld file correctly" do
      parser = MavenIndexParser.new(@test_file)
      packages = parser.parse

      assert_equal 2, packages.keys.count
      assert packages.key?("org.springframework:spring-core")
      assert packages.key?("org.hibernate:hibernate-core")

      spring = packages["org.springframework:spring-core"]
      assert_equal "org.springframework", spring[:group_id]
      assert_equal "spring-core", spring[:artifact_id]
      assert_equal 2, spring[:versions].count
      assert_equal "5.3.0", spring[:versions][0][:number]
      assert_equal "5.3.1", spring[:versions][1][:number]
    end
  end
end
