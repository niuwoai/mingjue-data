require 'csv'
require 'json'
require 'minitest/autorun'
require_relative 'prepare_shell_authorization_review'

class PrepareShellAuthorizationReviewTest < Minitest::Test
  def test_output_is_blind_and_retains_exact_pair_mapping
    output = File.join(ShellAuthorizationReview::OUT, '独立测试盲审.csv')
    key_path = ShellAuthorizationReview::KEY
    skip 'Run the review packet generator before testing its output' unless File.file?(output) && File.file?(key_path)

    csv = CSV.read(output, headers: true, encoding: 'bom|utf-8')
    key = JSON.parse(File.read(key_path))
    assert_equal 200, csv.size
    assert_equal 100, csv.map { |row| row['blind_pair_id'] }.uniq.size
    assert csv.all? { |row| row['blind_sample_id'].start_with?('SAMPLE-') }
    assert csv.all? { |row| row['human_gate'].to_s.empty? && row['evidence'].to_s.empty? }
    refute csv.headers.any? { |header| header.match?(/expected|label|source_id|split/i) }
    assert_equal 200, key.fetch('labels').size
    assert_equal %w[allow needs_review], key.fetch('labels').map { |row| row.fetch('expected_gate') }.uniq.sort
    assert_equal 100, key.fetch('labels').map { |row| row.fetch('source_group_id') }.uniq.size
    assert_equal '600', File.stat(key_path).mode.to_s(8)[-3..]
  end
end
