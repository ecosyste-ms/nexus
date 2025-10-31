class Package < ApplicationRecord
  belongs_to :repository
  has_many :versions, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :repository_id }
  validates :group_id, presence: true
  validates :artifact_id, presence: true

  scope :recently_updated, ->(since = 1.week.ago) { where('packages.last_modified >= ?', since).order('packages.last_modified DESC') }
  scope :for_repository, ->(repository_name) { joins(:repository).where(repositories: { name: repository_name }) }

  before_validation :set_name_from_parts, if: -> { name.blank? && group_id.present? && artifact_id.present? }

  private

  def set_name_from_parts
    self.name = "#{group_id}:#{artifact_id}"
  end
end
