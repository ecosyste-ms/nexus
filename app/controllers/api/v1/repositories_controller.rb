module Api
  module V1
    class RepositoriesController < ApplicationController
      before_action :authenticate_api_key!, only: [:reindex, :sync]

      def index
        repositories = Repository.all.order(name: :asc)
        render json: repositories.map { |r| repository_json(r) }
      end

      def show
        repository = Repository.find_by_normalized_name!(params[:name])
        render json: repository_json(repository)
      end

      def packages
        repository = Repository.find_by_normalized_name!(params[:name])
        packages = repository.packages.pluck(:name)
        render json: packages
      end

      def recent
        repository = Repository.find_by_normalized_name!(params[:name])
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
        repository = Repository.find_by_normalized_name!(params[:name])
        render json: {
          name: repository.name,
          last_indexed_at: repository.last_indexed_at,
          package_count: repository.package_count,
          status: repository.status
        }
      end

      def reindex
        repository = Repository.find_by_normalized_name!(params[:name])
        IndexRepositoryWorker.perform_async(repository.id)
        render json: { message: 'Reindex scheduled', repository: repository.name }
      end

      def sync
        repositories_data = params[:_json] || params[:repositories]

        unless repositories_data.is_a?(Array)
          return render json: { error: 'Expected array of repositories' }, status: :bad_request
        end

        repositories_to_index = []
        synced = Repository.transaction do
          repositories_data.map do |repo_data|
            name = Repository.normalize_name_value(repo_data[:name])
            repo = Repository.find_or_initialize_by(name: name)
            url_changed = repo.persisted? && repo.url != repo_data[:url]

            repo.url = repo_data[:url]
            repo.ecosystem = repo_data[:ecosystem].presence || 'maven'
            repo.status = 'pending' if repo.new_record? || url_changed
            repo.save!

            repositories_to_index << repo if url_changed || repo.needs_reindex?
            repo.name
          end
        end

        repositories_to_index.uniq(&:id).each do |repo|
          IndexRepositoryWorker.perform_async(repo.id)
        end

        render json: { message: 'Repositories synced', count: synced.uniq.count, repositories: synced.uniq }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: 'Invalid repository', details: e.record.errors.full_messages }, status: :unprocessable_entity
      end

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
