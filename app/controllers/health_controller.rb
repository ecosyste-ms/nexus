class HealthController < ApplicationController
  def index
    render json: {
      status: 'ok',
      timestamp: Time.current,
      database: database_status
    }
  end

  private

  def database_status
    ActiveRecord::Base.connection.execute('SELECT 1')
    'connected'
  rescue StandardError
    'disconnected'
  end
end
