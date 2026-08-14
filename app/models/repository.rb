require 'ipaddr'
require 'uri'

class Repository < ApplicationRecord
  BLOCKED_ADDRESS_RANGES = [
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('100.64.0.0/10'),
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.0.0.0/24'),
    IPAddr.new('192.0.2.0/24'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('198.18.0.0/15'),
    IPAddr.new('198.51.100.0/24'),
    IPAddr.new('203.0.113.0/24'),
    IPAddr.new('224.0.0.0/4'),
    IPAddr.new('240.0.0.0/4'),
    IPAddr.new('::/128'),
    IPAddr.new('::1/128'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10'),
    IPAddr.new('ff00::/8'),
    IPAddr.new('2001:db8::/32')
  ].freeze

  has_many :packages, dependent: :destroy
  has_many :maven_artifacts, dependent: :delete_all

  before_validation :normalize_name

  validates :name, presence: true, uniqueness: true
  validates :name, format: {
    with: /\A[[:alnum:]][[:alnum:]._-]*\z/,
    message: 'may only contain letters, numbers, dots, underscores, and hyphens'
  }, allow_blank: true
  validates :url, presence: true
  validates :ecosystem, inclusion: { in: %w[maven] }
  validates :status, inclusion: { in: %w[pending indexing completed failed] }
  validate :url_is_public_http_url

  scope :pending, -> { where(status: 'pending') }
  scope :indexing, -> { where(status: 'indexing') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :recently_indexed, -> { where.not(last_indexed_at: nil).order(last_indexed_at: :desc) }

  def needs_reindex?
    last_indexed_at.nil? || last_indexed_at < ENV.fetch('REINDEX_INTERVAL_HOURS', 24).to_i.hours.ago
  end

  def mark_as_indexing!
    update!(status: 'indexing', error_message: nil)
  end

  def mark_as_completed!(package_count: nil)
    updates = {
      status: 'completed',
      last_indexed_at: Time.current,
      error_message: nil,
      index_size_bytes: nil
    }
    updates[:package_count] = package_count if package_count
    update!(updates)
  end

  def mark_as_failed!(error)
    update!(
      status: 'failed',
      error_message: error.to_s
    )
  end

  def url_is_public_http_url
    return if url.blank?

    uri = URI.parse(url)
    if !%w[http https].include?(uri.scheme) || uri.hostname.blank? || uri.userinfo.present?
      errors.add(:url, 'must be a public HTTP or HTTPS URL without credentials')
      return
    end

    errors.add(:url, 'must use a public host') if self.class.blocked_hostname?(uri.hostname)
  rescue URI::InvalidURIError
    errors.add(:url, 'must be a valid URL')
  end

  def normalize_name
    self.name = self.class.normalize_name_value(name)
  end

  def nexus_cursor
    cursor = metadata.to_h['nexus_cursor']
    cursor if cursor.is_a?(Hash)
  end

  def reset_index_state
    self.metadata = metadata.to_h.except('nexus_cursor')
    self.index_timestamp = nil
    self.index_chain_id = nil
    self.last_incremental_chunk = nil
    self.index_run_id = nil
  end

  def self.normalize_name_value(name)
    name.respond_to?(:strip) ? name.strip.downcase : name
  end

  def self.find_by_normalized_name!(name)
    find_by!(name: normalize_name_value(name))
  end

  def self.blocked_hostname?(hostname)
    normalized_hostname = hostname.to_s.downcase.delete_suffix('.')
    return true if normalized_hostname == 'localhost'
    return true if normalized_hostname.end_with?('.localhost', '.local', '.internal')

    address = IPAddr.new(normalized_hostname)
    blocked_address?(address)
  rescue IPAddr::InvalidAddressError
    false
  end

  def self.blocked_address?(address)
    ip_address = address.is_a?(IPAddr) ? address : IPAddr.new(address)
    ip_address = ip_address.native if ip_address.ipv4_mapped?
    BLOCKED_ADDRESS_RANGES.any? { |range| range.include?(ip_address) }
  rescue IPAddr::InvalidAddressError
    true
  end
end
