require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  context "validations" do
    subject { Repository.new(name: "test-repo", url: "http://example.com") }

    should validate_presence_of(:name)
    should validate_presence_of(:url)
    should validate_uniqueness_of(:name)
  end

  context "associations" do
    should have_many(:packages).dependent(:destroy)
  end

  context "scopes" do
    setup do
      @pending = Repository.create!(name: "pending-repo", url: "http://example.com", status: "pending")
      @indexing = Repository.create!(name: "indexing-repo", url: "http://example.com", status: "indexing")
      @completed = Repository.create!(name: "completed-repo", url: "http://example.com", status: "completed", last_indexed_at: 1.hour.ago)
      @failed = Repository.create!(name: "failed-repo", url: "http://example.com", status: "failed")
    end

    should "return pending repositories" do
      assert_includes Repository.pending, @pending
      assert_not_includes Repository.pending, @completed
    end

    should "return completed repositories" do
      assert_includes Repository.completed, @completed
      assert_not_includes Repository.completed, @pending
    end
  end

  context "#index_url" do
    should "return the correct index URL" do
      repo = Repository.new(url: "https://build.shibboleth.net/nexus/content/repositories/releases")
      assert_equal "https://build.shibboleth.net/nexus/content/repositories/releases/.index/nexus-maven-repository-index.gz", repo.index_url
    end
  end

  context "#needs_reindex?" do
    should "return true if never indexed" do
      repo = Repository.new(name: "test", url: "http://example.com", last_indexed_at: nil)
      assert repo.needs_reindex?
    end

    should "return true if last indexed beyond interval" do
      repo = Repository.new(name: "test", url: "http://example.com", last_indexed_at: 25.hours.ago)
      assert repo.needs_reindex?
    end

    should "return false if recently indexed" do
      repo = Repository.new(name: "test", url: "http://example.com", last_indexed_at: 1.hour.ago)
      assert_not repo.needs_reindex?
    end
  end

  context "status management" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
    end

    should "mark as indexing" do
      @repo.mark_as_indexing!
      assert_equal "indexing", @repo.status
      assert_nil @repo.error_message
    end

    should "mark as completed" do
      @repo.mark_as_completed!(package_count: 100, index_size: 1000)
      assert_equal "completed", @repo.status
      assert_equal 100, @repo.package_count
      assert_equal 1000, @repo.index_size_bytes
      assert_not_nil @repo.last_indexed_at
    end

    should "mark as failed" do
      error = StandardError.new("Test error")
      @repo.mark_as_failed!(error)
      assert_equal "failed", @repo.status
      assert_equal "Test error", @repo.error_message
    end
  end
end
