require "test_helper"

class VersionTest < ActiveSupport::TestCase
  context "validations" do
    should validate_presence_of(:number)
  end

  context "associations" do
    should belong_to(:package)
  end

  context "scopes" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
      @package = Package.create!(repository: @repo, name: "org.example:test", group_id: "org.example", artifact_id: "test")
      @recent_version = Version.create!(package: @package, number: "1.0.0", last_modified: 1.day.ago)
      @old_version = Version.create!(package: @package, number: "0.9.0", last_modified: 2.weeks.ago)
    end

    should "return recently updated versions" do
      assert_includes Version.recently_updated, @recent_version
      assert_not_includes Version.recently_updated, @old_version
    end

    should "filter by repository name" do
      other_repo = Repository.create!(name: "other-repo", url: "http://other.com")
      other_package = Package.create!(repository: other_repo, name: "org.other:lib", group_id: "org.other", artifact_id: "lib")
      other_version = Version.create!(package: other_package, number: "1.0.0")

      versions = Version.for_repository("test-repo")

      assert_includes versions, @recent_version
      assert_not_includes versions, other_version
    end

    should "work with chained scopes without ambiguous column errors" do
      # This tests the exact scenario that was failing in the controller
      # When joining packages and repositories, and filtering by last_modified
      versions = Version.for_repository("test-repo").recently_updated(1.week.ago)

      assert_includes versions, @recent_version
      assert_not_includes versions, @old_version
    end
  end
end
