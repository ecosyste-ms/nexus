require "test_helper"

class Api::V1::RepositoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_nexus_api_key = ENV['NEXUS_API_KEY']
    ENV['NEXUS_API_KEY'] = 'test-api-key'
  end

  teardown do
    if @previous_nexus_api_key
      ENV['NEXUS_API_KEY'] = @previous_nexus_api_key
    else
      ENV.delete('NEXUS_API_KEY')
    end
  end

  context "GET /api/v1/repositories" do
    setup do
      @repo1 = Repository.create!(name: "repo1", url: "http://example.com/repo1")
      @repo2 = Repository.create!(name: "repo2", url: "http://example.com/repo2")
    end

    should "return all repositories" do
      get "/api/v1/repositories"
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 2, json.count
      assert_equal ["repo1", "repo2"], json.map { |r| r["name"] }.sort
    end
  end

  context "GET /api/v1/repositories/:name" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
    end

    should "return repository details" do
      get "/api/v1/repositories/test-repo"
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal "test-repo", json["name"]
      assert_equal "http://example.com", json["url"]
    end

    should "match repository names without case sensitivity" do
      get "/api/v1/repositories/TEST-REPO"

      assert_response :success
      assert_equal "test-repo", JSON.parse(response.body)["name"]
    end
  end

  context "GET /api/v1/repositories/:name/packages" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
      @package1 = Package.create!(repository: @repo, name: "org.example:lib1", group_id: "org.example", artifact_id: "lib1")
      @package2 = Package.create!(repository: @repo, name: "org.example:lib2", group_id: "org.example", artifact_id: "lib2")
    end

    should "return package names" do
      get "/api/v1/repositories/test-repo/packages"
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 2, json.count
      assert_includes json, "org.example:lib1"
      assert_includes json, "org.example:lib2"
    end
  end

  context "GET /api/v1/repositories/:name/recent" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "http://example.com")
      @package = Package.create!(repository: @repo, name: "org.example:lib", group_id: "org.example", artifact_id: "lib", last_modified: 1.day.ago)
      @recent_version = Version.create!(package: @package, number: "1.0.0", last_modified: 1.day.ago)
      @old_version = Version.create!(package: @package, number: "0.9.0", last_modified: 2.weeks.ago)
    end

    should "return recently updated versions" do
      get "/api/v1/repositories/test-repo/recent?since=#{1.week.ago.iso8601}"
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal 1, json.count
      assert_equal "org.example:lib", json.first["package"]
      assert_equal "1.0.0", json.first["version"]
    end

    should "work without since parameter" do
      # This was causing the ambiguous column error
      get "/api/v1/repositories/test-repo/recent"
      assert_response :success

      json = JSON.parse(response.body)
      assert json.is_a?(Array)
    end
  end

  context "POST /api/v1/sync_repositories" do
    should "create new repositories" do
      repos_data = [
        { name: "new-repo", url: "http://example.com/new", ecosystem: "maven" }
      ]

      IndexRepositoryWorker.expects(:perform_async).once

      post "/api/v1/sync_repositories",
        params: repos_data.to_json,
        headers: api_headers

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 1, json["count"]
      assert_includes json["repositories"], "new-repo"

      repo = Repository.find_by(name: "new-repo")
      assert_not_nil repo
      assert_equal "http://example.com/new", repo.url
    end

    should "reject requests without an API key" do
      IndexRepositoryWorker.expects(:perform_async).never

      post "/api/v1/sync_repositories",
        params: [{ name: "new-repo", url: "https://repo.example.com" }].to_json,
        headers: { 'Content-Type' => 'application/json' }

      assert_response :unauthorized
      assert_nil Repository.find_by(name: "new-repo")
    end

    should "fail closed when the API key is not configured" do
      ENV.delete('NEXUS_API_KEY')

      post "/api/v1/sync_repositories",
        params: [{ name: "new-repo", url: "https://repo.example.com" }].to_json,
        headers: api_headers

      assert_response :unauthorized
      assert_nil Repository.find_by(name: "new-repo")
    end

    should "reject an invalid batch without saving part of it" do
      repositories = [
        { name: "valid-repo", url: "https://repo.example.com" },
        { name: "../../app", url: "https://repo.example.com" }
      ]

      IndexRepositoryWorker.expects(:perform_async).never

      assert_no_difference 'Repository.count' do
        post "/api/v1/sync_repositories", params: repositories.to_json, headers: api_headers
      end

      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["details"], "Name may only contain letters, numbers, dots, underscores, and hyphens"
    end

    should "reindex a recently indexed repository when its URL changes" do
      repository = Repository.create!(
        name: "existing-repo",
        url: "https://old.example.com",
        status: "completed",
        last_indexed_at: 1.hour.ago,
        index_timestamp: "2026-08-14T10:00:00Z",
        index_chain_id: "old-chain",
        last_incremental_chunk: 12,
        index_run_id: "26de7823-1538-4d5f-aa2a-8ea84e85d738",
        metadata: {
          "nexus_cursor" => {
            "index_id" => "old-index",
            "timestamp" => "2026-08-14T10:00:00Z"
          }
        }
      )
      IndexRepositoryWorker.expects(:perform_async).with(repository.id).once

      post "/api/v1/sync_repositories",
        params: [{ name: "EXISTING-REPO", url: "https://new.example.com" }].to_json,
        headers: api_headers

      assert_response :success
      assert_equal "https://new.example.com", repository.reload.url
      assert_equal "pending", repository.status
      assert_nil repository.nexus_cursor
      assert_nil repository.index_run_id
    end
  end

  context "POST /api/v1/repositories/:name/reindex" do
    setup do
      @repo = Repository.create!(name: "test-repo", url: "https://repo.example.com")
    end

    should "require an API key" do
      IndexRepositoryWorker.expects(:perform_async).never

      post "/api/v1/repositories/test-repo/reindex"

      assert_response :unauthorized
    end

    should "queue an index with a valid API key" do
      IndexRepositoryWorker.expects(:perform_async).with(@repo.id).once

      post "/api/v1/repositories/test-repo/reindex", headers: { 'X-API-Key' => 'test-api-key' }

      assert_response :success
    end
  end

  def api_headers
    {
      'Content-Type' => 'application/json',
      'X-API-Key' => 'test-api-key'
    }
  end
end
