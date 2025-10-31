require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get index with API information" do
    get root_url
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "Ecosyste.ms: Nexus", json["name"]
    assert json["description"].present?
    assert json["endpoints"].present?
    assert json["example_usage"].present?
  end

  test "should return JSON format" do
    get root_url
    assert_equal "application/json; charset=utf-8", response.content_type
  end
end
