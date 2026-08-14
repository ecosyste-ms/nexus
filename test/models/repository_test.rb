require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  context "validations" do
    subject { Repository.new(name: "test-repo", url: "http://example.com") }

    should validate_presence_of(:name)
    should validate_presence_of(:url)
    should validate_uniqueness_of(:name).case_insensitive

    should "reject names that can escape the work directory" do
      repository = Repository.new(name: "../../app", url: "https://repo.example.com")

      assert_not repository.valid?
      assert_includes repository.errors[:name], "may only contain letters, numbers, dots, underscores, and hyphens"
    end

    should "reject non-HTTP repository URLs" do
      repository = Repository.new(name: "test-repo", url: "file:///etc/passwd")

      assert_not repository.valid?
      assert_includes repository.errors[:url], "must be a public HTTP or HTTPS URL without credentials"
    end

    should "reject private repository addresses" do
      repository = Repository.new(name: "test-repo", url: "http://127.0.0.1:8080/repository")

      assert_not repository.valid?
      assert_includes repository.errors[:url], "must use a public host"
    end

    should "reject IPv4-mapped private repository addresses" do
      repository = Repository.new(name: "test-repo", url: "http://[::ffff:127.0.0.1]/repository")

      assert_not repository.valid?
      assert_includes repository.errors[:url], "must use a public host"
    end

    should "reject unsupported ecosystems" do
      repository = Repository.new(name: "test-repo", url: "https://repo.example.com", ecosystem: "npm")

      assert_not repository.valid?
      assert_includes repository.errors[:ecosystem], "is not included in the list"
    end

    should "normalize repository names before case-sensitive database matching" do
      repository = Repository.create!(name: " Repo.Example.COM ", url: "https://repo.example.com")

      assert_equal "repo.example.com", repository.name
      assert_not Repository.new(name: "REPO.EXAMPLE.COM", url: "https://other.example.com").valid?
    end
  end

  context "associations" do
    should have_many(:packages).dependent(:destroy)
    should have_many(:maven_artifacts).dependent(:delete_all)
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
      @repo.update!(index_size_bytes: 1000)
      @repo.mark_as_completed!(package_count: 100)
      assert_equal "completed", @repo.status
      assert_equal 100, @repo.package_count
      assert_nil @repo.index_size_bytes
      assert_not_nil @repo.last_indexed_at
    end

    should "mark as failed" do
      error = StandardError.new("Test error")
      @repo.mark_as_failed!(error)
      assert_equal "failed", @repo.status
      assert_equal "Test error", @repo.error_message
    end
  end

  context "index state" do
    should "read the nexus cursor from repository metadata" do
      cursor = { "index_id" => "central", "timestamp" => "2026-08-14T10:00:00Z" }
      repository = Repository.new(metadata: { "nexus_cursor" => cursor })

      assert_equal cursor, repository.nexus_cursor
    end

    should "clear the cursor and full index run when the source changes" do
      repository = Repository.new(
        metadata: { "nexus_cursor" => { "index_id" => "old" }, "other" => true },
        index_timestamp: "2026-08-14T10:00:00Z",
        index_chain_id: "old-chain",
        last_incremental_chunk: 12,
        index_run_id: "26de7823-1538-4d5f-aa2a-8ea84e85d738"
      )

      repository.reset_index_state

      assert_equal({ "other" => true }, repository.metadata)
      assert_nil repository.index_timestamp
      assert_nil repository.index_chain_id
      assert_nil repository.last_incremental_chunk
      assert_nil repository.index_run_id
    end
  end
end
