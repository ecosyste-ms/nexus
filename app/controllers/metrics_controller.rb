class MetricsController < ApplicationController
  def index
    render json: {
      repositories: {
        total: Repository.count,
        pending: Repository.pending.count,
        indexing: Repository.indexing.count,
        completed: Repository.completed.count,
        failed: Repository.failed.count
      },
      packages: {
        total: Package.count
      },
      versions: {
        total: Version.count
      }
    }
  end
end
