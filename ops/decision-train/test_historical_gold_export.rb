require 'minitest/autorun'
require 'csv'
require 'json'
require_relative 'historical_gold_queue'

class HistoricalGoldExportTest < Minitest::Test
  def test_historical_queue_is_blind_complete_and_redacted
    rows = CSV.read(HistoricalGoldQueue::OUTPUT, headers: true, encoding: 'bom|utf-8')
    audit = JSON.parse(File.read(HistoricalGoldQueue::AUDIT))

    assert_equal HistoricalGoldQueue::COLUMNS, rows.headers
    assert_equal 104, rows.length
    assert rows.all? { |row| row.fields.length == rows.headers.length }
    %w[human_gate human_risk human_authorization human_information_sufficiency human_evidence confidence annotator_id].each do |field|
      assert rows.all? { |row| row[field].to_s.empty? }
    end
    assert_equal false, audit['training_or_regression_overlap']
    assert_equal false, audit['model_outputs_or_weak_labels_exported']
    assert_equal 0, audit['sensitive_patterns_remaining']
    assert_equal 0, audit['human_gold_rows']
    assert_equal 58, audit['unique_source_sessions']
    assert_equal 4, audit['max_rows_per_source_session']
    assert_equal '600', format('%o', File.stat(HistoricalGoldQueue::OUTPUT).mode & 0o777)
  end
end
