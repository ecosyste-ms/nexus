class Version < ApplicationRecord
  belongs_to :package

  validates :number, presence: true, uniqueness: { scope: :package_id }

  scope :recently_updated, ->(since = 1.week.ago) { where('last_modified >= ?', since).order(last_modified: :desc) }
  scope :for_repository, ->(repository_name) {
    joins(package: :repository).where(repositories: { name: repository_name })
  }
end
