require 'minitest/autorun'
require_relative 'short_data'

class ShortDataTest < Minitest::Test
  def setup
    @dir=File.join(ShortTrial::OUT,'dataset')
    @train=DiskTrial.rows(File.join(@dir,'train.jsonl'))
    @test=DiskTrial.rows(File.join(@dir,'locked_test_candidate.jsonl'))
  end

  def test_balance_and_unique_inputs
    assert_equal 4000,@train.size
    assert_equal 2000,@train.count { |r| r.dig('targets','gate','label')=='needs_review' }
    assert_equal 4000,@train.map { |r| JSON.generate(r['state']) }.uniq.size
    short=@train.select { |r| r['id'].start_with?('SHT4-') }
    assert_equal 2880,short.size
    assert_equal 1440,short.count { |r| r.dig('targets','gate','label')=='needs_review' }
    refute @train.any? { |r| r['state']['command']=='mkfs.ext4 /dev/nvme0n1' }
  end

  def test_new_holdout_does_not_share_input_or_combination_group
    assert_equal 500,@test.size
    assert_empty @train.map { |r| r['group_id'] } & @test.map { |r| r['group_id'] }
    assert_empty @train.map { |r| JSON.generate(r['state']) } & @test.map { |r| JSON.generate(r['state']) }
  end

  def test_authorization_pair_changes_only_user_text
    rows=DiskTrial.rows(File.join(ShortTrial::OUT,'candidates.jsonl'))
    [2,6].each do |variant|
      a=rows.find { |r| r['id']=="SHT4-format_env_holdout-0-#{variant}" }
      b=rows.find { |r| r['id']=="SHT4-format_env_holdout-0-#{variant+1}" }
      assert_equal 'allow',a.dig('targets','gate','label')
      assert_equal 'needs_review',b.dig('targets','gate','label')
      assert_equal a['state'].reject { |k,_| k=='visible_user_context_candidates' },b['state'].reject { |k,_| k=='visible_user_context_candidates' }
    end
  end

  def test_missing_environment_is_not_a_label_shortcut
    short=@train.select { |r| r['id'].start_with?('SHT4-') }
    %w[allow needs_review].each do |label|
      modes=short.select { |r| r.dig('targets','gate','label')==label }.map do |r|
        s=r['state']; s.key?('observed_target_evidence') ? s['observed_target_evidence'] : 'ABSENT'
      end.uniq
      assert_equal 4,modes.size
      rows=short.select { |r| r.dig('targets','gate','label')==label }
      grouped=rows.group_by { |r| s=r['state']; s.key?('observed_target_evidence') ? s['observed_target_evidence'] : 'ABSENT' }
      grouped.each_value { |r| assert_equal 2,r.map { |x| x['state']['requested_sandbox_permissions'] }.uniq.size }
    end
    assert DiskTrial.rows(File.join(ShortTrial::OUT,'unknown-quarantine.jsonl')).all? { |r| r['decision']=='unknown' && !r['training_use'] }
  end
end
