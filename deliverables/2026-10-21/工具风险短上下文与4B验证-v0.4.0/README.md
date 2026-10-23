# 第四轮交付入口

先看试训结果报告.md，再看验收结果.json与本地下载与训练核验.json。正式训练集仅为dataset/train.jsonl；新测试为dataset/locked_test_candidate.jsonl；regression.jsonl是此前观察过的回归。候选、标注审计与旧草案不参与本轮训练。

## 模型与复现

2B基座internlm/Intern-Decision-2B固定revision8797836c65fc91a2435b1fb6850b5f0aabd75cc3；官方upstream固定commit3572c8a68b5df5dafe02d0e093989ba8ec0183bc。原生decision位置全词表交叉熵，BF16/LoRA r8/alpha16/5e-5/累积16/平衡曝光4096/最大1536tokens。运行环境、包版本、服务状态与源码哈希见trial-004/service-verification.json。

source-snapshot为运行与数据准备源码快照；生成器依赖本仓库ops/decision-pipeline及前几轮交付数据，不是独立安装包。使用已冻结dataset可直接训练，无需重新调用标注API。需另行准备相同基座、upstream、GPU与原记录的Python环境；不要执行数据中的命令。没有自动续训CLI，不得覆盖已完成运行目录。4B工程探测（若触发）输出在probe-4b-001，不代表已完成全量4B训练。

本交付不含模型基座、任何访问凭据、原始私人会话全集或生产审批接入；数据标签是弱监督与合成规则，人工金标为0。
