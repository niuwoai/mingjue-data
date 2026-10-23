# 历史工具调用弱标签流水线

当前版本：0.3.0；更新：2026-10-21。

处理 2026-10-20 固定抽样的 10,000 条 Codex 命令，保留 290 个历史血缘组及原始五集合划分。`prepare.rb` 校验原始哈希、追加脱敏；`annotate.rb` 经现有本地模型网关调用教师并校验 JSON 枚举、ID 和逐字证据；失败批可恢复。

`select_review.rb --fixed` 选全部 894 条测试候选与 600 条固定随机样本，复核输入不包含教师答案。完成后再覆盖所有高风险和拦截/复核候选。`export.rb --input ... --labels ... --review ... --output ...` 隔离分歧和 unknown，输出原五集合、审计标签及哈希清单。标签仍全部为 AI 弱标签，human_verified=false。

`audit_inputs.rb` 仅生成 CPU token 化检查用的占位输入，严禁训练。正式训练必须使用 exporter 产出的 manifest。核心校验可运行 `ruby ops/decision-pipeline/test_pipeline.rb`。

限制：模型互审并非人工金标；当前只校验精确输入重复，未完成语义去重。少量危险/越权样本不足以证明生产拦截能力。日志只保留脱敏历史，任何历史命令均不执行。
