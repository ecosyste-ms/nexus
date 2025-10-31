class HomeController < ApplicationController
  def index
    render json: {
      name: "Ecosyste.ms: Nexus",
      description: "A Maven repository indexer service that downloads and parses Maven Nexus repository indexes to provide package discovery data",
      documentation: "https://github.com/ecosyste-ms/nexus",
      api_version: "v1",
      endpoints: {
        repositories: "/api/v1/repositories",
        sync: "/api/v1/sync_repositories",
        health: "/health",
        metrics: "/metrics"
      },
      example_usage: {
        list_repositories: "GET /api/v1/repositories",
        get_packages: "GET /api/v1/repositories/:name/packages",
        get_recent: "GET /api/v1/repositories/:name/recent?since=2025-10-29",
        repository_status: "GET /api/v1/repositories/:name/status",
        trigger_reindex: "POST /api/v1/repositories/:name/reindex"
      },
      source: "https://github.com/ecosyste-ms/nexus",
      license: "AGPL-3.0"
    }
  end
end
