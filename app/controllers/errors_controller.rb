class ErrorsController < ApplicationController
  def not_found
    render json: { error: 'Not found' }, status: :not_found
  end

  def unprocessable
    render json: { error: 'Unprocessable entity' }, status: :unprocessable_entity
  end

  def internal
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end
end
