require "test_helper"

class Api::V1::RepositoriesControllerTest < ActionDispatch::IntegrationTest
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

  context "POST /api/v1/sync_repositories" do
    should "create new repositories" do
      repos_data = [
        { name: "new-repo", url: "http://example.com/new", ecosystem: "maven" }
      ]

      IndexRepositoryWorker.expects(:perform_async).once

      post "/api/v1/sync_repositories",
        params: repos_data.to_json,
        headers: { 'Content-Type' => 'application/json' }

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 1, json["count"]
      assert_includes json["repositories"], "new-repo"

      repo = Repository.find_by(name: "new-repo")
      assert_not_nil repo
      assert_equal "http://example.com/new", repo.url
    end
  end
end
