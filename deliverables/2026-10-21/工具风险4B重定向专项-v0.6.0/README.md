# 第六轮4B重定向专项

先看重定向专项结果报告.md、验收结果.json、本地下载与训练核验.json。正式输入仅为dataset；candidates和preflight-draft-v1只作审计。未知授权样本保留隔离，未硬改为正常或危险。人工金标0。

trial-006/adapter为本轮完整4B LoRA权重；冻结旧15条漏放.jsonl是已观察回归，不是新测试。新600条按shell包装、目标和任务组合留出，操作语义仍有共享。原基座、上轮完整4B与本轮在相同600条上比较，旧500条和原26条另列回归。

source-snapshot记录运行与数据准备代码，数据准备依赖本仓库decision-pipeline及此前交付；不是独立安装包。使用冻结dataset无需再次调用标注API。4B原基座、固定upstream与Python环境需另行准备，具体版本见运行证据。所有数据命令只作文本，不得执行。此包未上传Hugging Face或接入生产审批。
