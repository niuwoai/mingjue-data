require 'minitest/autorun'
require_relative 'historical_gold_queue'

class HistoricalGoldQueueTest < Minitest::Test
  def test_redacts_secrets_contact_details_and_user_paths
    counts = Hash.new(0)
    value = 'Bearer abc token=abc alice@example.com 13800138000 ~/Sites/private /Users/alice/private'
    output = HistoricalGoldQueue.safe_text(value, counts)

    refute_match(/Bearer abc|token=abc|alice@example.com|13800138000|\/Users\/alice|~\/Sites/, output)
    assert_equal 1, counts[:bearer]
    assert_equal 1, counts[:credential_assignment]
    assert_equal 1, counts[:email]
    assert_equal 1, counts[:phone]
    assert_operator counts[:home_path] + counts[:user_path], :>=, 2
  end

  def test_export_is_blind_and_omits_source_identifiers
    row = {
      'session_id' => 'private-session-id', 'source_file' => 'private-source-path',
      'sample_id' => 'old-sample-id', 'command' => 'rm -rf ~/private-target',
      'cwd' => '~/Sites/private', 'preceding_user_records' => [{ 'text' => 'remove ~/private-target' }],
      'requested_sandbox_permissions' => 'workspace-write', 'approval_justification' => ''
    }
    result = HistoricalGoldQueue.export_row(row, 1, Hash.new(0))

    assert_equal HistoricalGoldQueue::COLUMNS, result.keys
    assert_equal 'HIST-0001', result['sample_id']
    assert_equal 'home_or_workspace', result['working_directory_kind']
    assert_equal '', result['human_gate']
    refute_includes result.values.join(' '), 'private-session-id'
    refute_includes result.values.join(' '), 'private-source-path'
    refute_includes result.values.join(' '), 'old-sample-id'
  end

  def test_sampling_caps_examples_per_source_session
    rows = Array.new(12) do |index|
      { 'session_id' => "session-#{index / 6}", 'command' => "tool-#{index}",
        'preceding_user_records' => [{ 'text' => 'context' }] }
    end
    sampled = HistoricalGoldQueue.sample(rows)

    assert_equal 8, sampled.length
    assert sampled.group_by { |row| row['session_id'] }.values.all? { |items| items.length <= 4 }
  end
end
