class ApplicationController < ActionController::API
  def authenticate_api_key!
    expected_key = ENV['NEXUS_API_KEY']
    provided_key = request.headers['X-API-Key']

    authenticated = expected_key.present? && provided_key.present? &&
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(provided_key),
        Digest::SHA256.hexdigest(expected_key)
      )

    render json: { error: 'Unauthorized' }, status: :unauthorized unless authenticated
  end
end
