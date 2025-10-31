class Repository < ApplicationRecord
  has_many :packages, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :url, presence: true
  validates :status, inclusion: { in: %w[pending indexing completed failed] }

  scope :pending, -> { where(status: 'pending') }
  scope :indexing, -> { where(status: 'indexing') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :recently_indexed, -> { where.not(last_indexed_at: nil).order(last_indexed_at: :desc) }

  def index_url
    "#{url}/.index/nexus-maven-repository-index.gz"
  end

  def needs_reindex?
    last_indexed_at.nil? || last_indexed_at < ENV.fetch('REINDEX_INTERVAL_HOURS', 24).to_i.hours.ago
  end

  def mark_as_indexing!
    update!(status: 'indexing', error_message: nil)
  end

  def mark_as_completed!(package_count: nil, index_size: nil)
    updates = {
      status: 'completed',
      last_indexed_at: Time.current,
      error_message: nil
    }
    updates[:package_count] = package_count if package_count
    updates[:index_size_bytes] = index_size if index_size
    update!(updates)
  end

  def mark_as_failed!(error)
    update!(
      status: 'failed',
      error_message: error.to_s
    )
  end
end
