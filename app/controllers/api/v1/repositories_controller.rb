module Api
  module V1
    class RepositoriesController < ApplicationController
      def index
        repositories = Repository.all.order(name: :asc)
        render json: repositories.map { |r| repository_json(r) }
      end

      def show
        repository = Repository.find_by!(name: params[:name])
        render json: repository_json(repository)
      end

      def packages
        repository = Repository.find_by!(name: params[:name])
        packages = repository.packages.pluck(:name)
        render json: packages
      end

      def recent
        repository = Repository.find_by!(name: params[:name])
        since = params[:since] ? Time.parse(params[:since]) : 1.week.ago

        versions = Version.for_repository(repository.name)
                         .recently_updated(since)
                         .includes(package: :repository)

        results = versions.map do |version|
          {
            package: version.package.name,
            version: version.number,
            updated_at: version.last_modified
          }
        end

        render json: results
      end

      def status
        repository = Repository.find_by!(name: params[:name])
        render json: {
          name: repository.name,
          last_indexed_at: repository.last_indexed_at,
          package_count: repository.package_count,
          status: repository.status
        }
      end

      def reindex
        repository = Repository.find_by!(name: params[:name])
        IndexRepositoryWorker.perform_async(repository.id)
        render json: { message: 'Reindex scheduled', repository: repository.name }
      end

      def sync
        repositories_data = params[:_json] || params[:repositories]

        unless repositories_data.is_a?(Array)
          return render json: { error: 'Expected array of repositories' }, status: :bad_request
        end

        synced = []
        repositories_data.each do |repo_data|
          repo = Repository.find_or_initialize_by(name: repo_data[:name])
          repo.url = repo_data[:url]
          repo.ecosystem = repo_data[:ecosystem] || 'maven'
          repo.status = 'pending' if repo.new_record?

          if repo.save
            synced << repo.name
            IndexRepositoryWorker.perform_async(repo.id) if repo.needs_reindex?
          end
        end

        render json: { message: 'Repositories synced', count: synced.count, repositories: synced }
      end

      private

      def repository_json(repository)
        {
          name: repository.name,
          url: repository.url,
          ecosystem: repository.ecosystem,
          status: repository.status,
          last_indexed_at: repository.last_indexed_at,
          package_count: repository.package_count,
          index_size_bytes: repository.index_size_bytes,
          error_message: repository.error_message
        }
      end
    end
  end
end
