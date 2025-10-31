require "test_helper"

class PackageTest < ActiveSupport::TestCase
  context "validations" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
    end

    subject { Package.new(repository: @repo, name: "test:package", group_id: "org.example", artifact_id: "test") }

    should validate_presence_of(:group_id)
    should validate_presence_of(:artifact_id)
  end

  context "associations" do
    should belong_to(:repository)
    should have_many(:versions).dependent(:destroy)
  end

  context "#set_name_from_parts" do
    should "automatically set name from group_id and artifact_id" do
      repo = Repository.create!(name: "test-repo", url: "http://example.com")
      package = Package.new(repository: repo, group_id: "org.example", artifact_id: "test-lib")
      package.valid?
      assert_equal "org.example:test-lib", package.name
    end
  end

  context "scopes" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
      @recent = Package.create!(repository: @repo, name: "recent:package", group_id: "recent", artifact_id: "package", last_modified: 1.day.ago)
      @old = Package.create!(repository: @repo, name: "old:package", group_id: "old", artifact_id: "package", last_modified: 2.weeks.ago)
    end

    should "return recently updated packages" do
      assert_includes Package.recently_updated, @recent
      assert_not_includes Package.recently_updated, @old
    end
  end
end
