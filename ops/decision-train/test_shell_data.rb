require 'minitest/autorun'
require 'json'

class ShellDatasetTest < Minitest::Test
  ROOT=ARGV.shift || File.expand_path('../../deliverables/2026-10-21/工具风险4B重定向专项-v0.6.0',__dir__)

  def rows(name)
    File.readlines(File.join(ROOT,'dataset',name+'.jsonl')).map { |line| JSON.parse(line) }
  end

  def test_sizes_and_retention
    train=rows('train')
    assert_equal 6000,train.size
    assert_equal 6000,train.map { |r| JSON.generate(r['state']) }.uniq.size
    assert_equal 3000,train.count { |r| r.dig('targets','gate','label')=='needs_review' }
    assert_equal 2000,train.count { |r| r['id'].start_with?('SHR6-') }
    test=rows('locked_test_candidate')
    assert_equal 600,test.size
    assert_equal 300,test.count { |r| r.dig('targets','gate','label')=='needs_review' }
  end

  def test_split_and_known_test_isolation
    train=rows('train'); test=rows('locked_test_candidate'); old=rows('regression')
    assert_empty train.map { |r| r['group_id'] }.uniq & test.map { |r| r['group_id'] }.uniq
    assert_empty test.map { |r| JSON.generate(r['state']) } & old.map { |r| JSON.generate(r['state']) }
    assert_empty train.map { |r| r['id'] } & old.map { |r| r['id'] }
  end

  def test_authorization_pairs_and_missing_facts
    train=rows('train').select { |r| r['id'].start_with?('SHR6-') }
    a=train.find { |r| r['id']=='SHR6-cat_redirect-0-2' }
    b=train.find { |r| r['id']=='SHR6-cat_redirect-0-3' }
    assert_equal 'allow',a.dig('targets','gate','label')
    assert_equal 'needs_review',b.dig('targets','gate','label')
    assert_equal a['state'].reject { |key,_| key=='visible_user_context_candidates' },b['state'].reject { |key,_| key=='visible_user_context_candidates' }
    modes=->(r) { r['state'].key?('observed_target_evidence') ? r['state']['observed_target_evidence'] : :missing }
    %w[allow needs_review].each do |label|
      pool=train.select { |r| r.dig('targets','gate','label')==label }
      assert_equal 4,pool.map(&modes).uniq.size
      pool.group_by(&modes).each_value { |rs| assert_equal 2,rs.map { |r| r['state']['requested_sandbox_permissions'] }.uniq.size }
    end
  end
end
