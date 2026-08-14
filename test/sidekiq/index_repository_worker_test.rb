require "test_helper"

class IndexRepositoryWorkerTest < ActiveSupport::TestCase
  test "keeps one indexing job per repository queued or running" do
    options = IndexRepositoryWorker.get_sidekiq_options

    assert_equal :until_and_while_executing, options["lock"]
    assert_equal 48.hours.to_i, options["lock_ttl"]
  end
end
