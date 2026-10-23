# 4000条磁盘专项第三轮

以 dataset/manifest.json 为最终冻结清单，train.jsonl 为4000条唯一训练，locked_test_candidate.jsonl 为独立测试400条，regression.jsonl 为已观察回归。候选和draft-v1是未采用或尚未选入的生成记录，不是训练集合。

已完成训练、双版本评估、重载与服务恢复。先看 **试训结果报告.md**：400条合成测试全对，但原始格式化案例仍漏放，预注册实验门槛未通过；人工金标仍为0。

- 权重：`trial-003/adapter/`
- 最终训练及留出：`dataset/`
- 来源、去重与分区：`数据隔离与平衡审计.json`
- 验收：`验收结果.json`
- 实际下载、源码与每批核验：`本地下载与训练核验.json`
- 原始短输入的四条诊断：`trial-003/post-result-diagnostic.json`（结果后诊断，不是独立测试）

`source-snapshot/`是原路径文件快照，不是可直接运行所有生成器的独立项目；需放回原仓库 `ops/decision-train/`。生成器引用的模型客户端支持文件在 `support/decision-pipeline/`，对应原仓库 `ops/decision-pipeline/`；不包含任何网关配置或凭据。单纯重训冻结数据无需再次调用大模型复核。
