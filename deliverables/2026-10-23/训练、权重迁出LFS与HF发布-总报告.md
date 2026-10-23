# 4B 复训、权重迁出 GitHub LFS 与 HF 发布：总报告

日期：2026-10-23
远端训练机：q4（`ssh -p 50022 root@h2.niuwoai.com`，RTX 5070 Ti 16GB）
本地仓库：`/Users/rocky/Sites/rsi`，远端 `git@github.com:niuwoai/mingjue-data.git`

## 摘要

1. **训练**：在 q4 上用与 v0.13.0（2B）完全相同的 28,000 条冻结数据、同一套超参，把基座换成 Intern-Decision-4B 跑完整单轮 LoRA（1,750 步），产物 `trial-014`。五条预注册门槛全过，2B 当年在门槛 2、3 上失败。
2. **权重迁出**：权重与续训快照原本占 GitHub LFS 约 1.3 GB，已整体迁到 Hugging Face。GitHub 当前历史里权重文件为 0，LFS 只剩可 diff 的数据集/标注表/评测集 218 个对象。
3. **发布**：三个 HF 仓库公开可用，README 里写的 `subfolder=` 加载路径已用 `PeftConfig` 实测 8/8 通过（v0.14 是独立仓库）。q4 上另有 5 份从未入过 git 的 adapter（`trial-007`~`trial-011`）已补进归档仓库，远端权重 sha256 与训练机逐字节一致。
4. **未完成**：GitHub 免费额度里的历史 LFS 存储尚未真正释放，删仓需要 `delete_repo` 权限，当前 token 不具备。

---

## 一、q4 上这一次是怎么训练的

### 冻结输入（未做任何重生成）

| 项 | 值 |
|---|---|
| 数据目录 | `/home/ml-data/rsi-tool-gate-shell-auth-v13/dataset`（v0.13.0 原样拷贝，`diff -rq` = IDENTICAL） |
| `manifest.json` sha256 | `3c57f5770c7c1b1d8d8fad5c6c1866ed9a9d9e79b941e7c998845ba842605b47` |
| `train.jsonl` | 28,000 条（14,000 / 14,000），sha256 `9f9dba46…` |
| `locked_test_candidate.jsonl` | 1,200 条 = 600 组同命令不同授权，sha256 `2d927131…` |
| `regression.jsonl` | 6,673 条，sha256 `f068bcc9…` |
| 基座 | `/home/ml-data/rsi-smoke/model-4b` ≡ `internlm/Intern-Decision-4B`，revision `1e65a988dacbcf00b84aee7366f9e47563407000` |
| 训练引擎 | `train.py` v0.18.0-rc2，sha256 `723216dc…`，与 2B 那次逐字节相同 |

### 训练配置（与 2B 对齐）

| 项 | 值 |
|---|---|
| LoRA | r=8 / alpha=16 / dropout=0.05，全 Linear |
| lr / seed | 5e-5 / 20261021 |
| 有效 batch | 16（梯度累积） |
| max length | 1,536，超长不截断、直接排除 |
| optimizer steps | 1,750 |
| 阈值 | 固定 0.5，不做自动调阈值 |

唯一非对齐项：2B 走 `balanced_draws=0` 全量乱序，4B 走 `balanced_draws=28000` 分层循环池。两边训练行的集合与曝光次数完全相同，batch 组成与顺序不同。

### 运行方式

```bash
# 训练 + 全量评估
cd /home/ml-data/rsi-tool-gate-shell-auth-4b-v14
systemctl start rsi-tool-gate-4b-v14.service

# 2B 在同一份数据、同一 6,673 行上的回归对照
systemctl start rsi-2b-regression.service
```

实测：约 10.7 秒/步，GPU 占用 57~91%、显存峰值 12,012 MiB / 16 GB；从 23:38 加载到 06:36 完成 1,750 步，墙钟约 7 小时（含模型加载与评估）。

---

## 二、结果

### 锁定测试 1,200 条（固定阈值 0.5）

| 模型 | tp | fp | fn | tn | 召回 | 误拦率 | 准确率 | macro_f1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2B v0.13（基线） | 600 | 75 | 0 | 525 | 100% | 12.50% | 93.75% | 0.9373 |
| **4B v0.14** | 600 | 0 | 0 | 600 | 100% | 0% | 100% | 1.0000 |
| 4B 基座（未训练） | 324 | 0 | 276 | 600 | 54.00% | 0% | 77.00% | 0.7572 |

组级（600 组同命令不同授权，要求一组两侧全对）：4B **600/600**，2B **525/600**，4B 基座 **324/600**。

### 历史回归 6,673 条（43 行超长排除，实际评估 6,630 行）

| 模型 | tp | fp | fn | tn | 漏放率 | 误拦率 | 准确率 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2B v0.13（同数据重跑） | 2,958 | 109 | 0 | 3,563 | 0% | 2.968% | 98.356% |
| **4B v0.14** | 2,956 | 19 | 2 | 3,653 | **0.0676%** | **0.517%** | 99.683% |

4B 相对 2B：误拦少 90 条（19 vs 109），漏放多 2 条（2 vs 0）。这是唯一一项 2B 更优的指标。

### 错误结构（本轮新增逐行 predictions）

| 文件 | 行数 | sha256 |
|---|---:|---|
| `regression-predictions-adapter.jsonl` | 6,630 | `719a9d1ecb3c32aa7c23156070688d18c0ad10c5cb0dfb940d8b7dbfc57105ba` |
| `regression-predictions-base.jsonl` | 6,630 | `a6281a1c54940227f1dad13d8448cd95c3b618c324cdec2ddfe265e677c1a566` |

每行仅 `id`/`group_id`/`label`/`probability`/`blocked`/`correct`，不含命令文本与路径。21 条错误落在 6 个命令族、可由 5 个上下文模板完全解释，其中 3 个模板在 28,000 条训练集里出现 0 次——错的不是命令理解，是"命令 + 上下文"组合在训练时从未出现。明细见 `deliverables/2026-10-22/工具调用二分类门控-4B同数据复训-v0.14.0/实验报告.md`。

---

## 三、权重迁出 GitHub LFS

### 为什么迁

GitHub 免费额度 LFS 存储 1 GB，权重与续训快照占约 1.3 GB。数据（jsonl/csv）需要留在 GitHub 才能 diff，权重不需要。

### 迁到哪

| 内容 | 位置 |
|---|---|
| 历史 LoRA adapter（8 份） | `renlu/mingjue-tool-gate-lora-history`（按 `subfolder` 加载） |
| 正式版 v0.14.0 adapter | `renlu/intern-decision-4b-tool-gate-v0.14.0`（独立仓库） |
| `training-state.pt`（9 份） | `datasets/renlu/mingjue-tool-gate-evidence` |

台账落在仓库根 `模型权重归档.md`：原 git 路径、HF 位置、基座、训练主题、sha256 逐条对应。

### 怎么做的

```bash
git bundle create /tmp/rsi-pre-migration.bundle --all     # 先备份 10 个 commit
git filter-repo --path-glob '*.safetensors' --path-glob '*.pt' --invert-paths --force
printf '\n*.safetensors\n*.pt\n' >> .gitignore           # 防再入库
git push --force origin main
```

### 迁移后核验（实测）

| 断言 | 结果 |
|---|---|
| 当前树权重文件数 | 0 |
| 历史各 commit 权重文件数 | 0（237 → 218 个 LFS 对象） |
| 剩余 LFS 体积 | 218 个对象、544,844,120 字节（约 0.51 GiB），全部是可 diff 数据 |
| 台账是否保留 | `模型权重归档.md` 在位 |
| 远端 HEAD 与本地一致 | `329972a226903342d92673eef50a98b2bcee5307` |
| 工作区干净度 | `git status --porcelain` 0 行 |

---

## 四、Hugging Face 发布与可用性验证

### 已上线

| 仓库 | commit | 状态 |
|---|---|---|
| `renlu/mingjue-tool-gate-lora-history` | `e00d769b…`（13 个 subfolder） | 200 |
| `datasets/renlu/mingjue-tool-gate-evidence` | `d494733c…` | 200 |
| `renlu/intern-decision-4b-tool-gate-v0.14.0` | `1cb7424b…`，模型卡修订 `65ccedf0…` | 200 |

命名空间说明：原脚本默认写 `niuwoai/`，但 HF 上无该用户/组织，实际登录账号是 `renlu`，故发布到 `renlu/`，模型卡与 `upload.sh` 已同步。

### 文件完整性（按 API 实列）

- 归档仓库：13 个目录 × (`adapter_config.json` + `adapter_model.safetensors` + `README.md`) + 顶层 `README.md` + `.gitattributes` = 41 文件。其中 9 个目录是曾进过 git 的历史 adapter（8 份台账 + `v0.4.0-probe-4b-001`），另 5 个是 q4 单机上从未入过 git 的 `trial-007`~`trial-011`（见 §5.2）。
- 证据仓库：9 个目录各 1 份 `training-state.pt` + `README.md` + `.gitattributes` = 11 文件。

### 加载路径实测（这是 README 里唯一可证伪的断言）

在 q4 上用 peft 0.21.2 直接跑 `PeftConfig.from_pretrained(..., subfolder=...)`：

| subfolder | 结果 |
|---|---|
| `2b-fit-001` | OK r=8 alpha=16 |
| `v0.1.0-trial-001` … `v0.6.0-trial-006`（共 6 个） | OK r=8 alpha=16 |
| `v0.4.0-probe-4b-001` | OK r=8 alpha=16 |

8/8 全部可解析。v0.14 走独立仓库根目录，另有一次端到端复现：从 HF 拉回 q4 重新加载并重算 8 条冻结样本，`reproduced: true`、`mismatches: []`、概率逐位一致。

补档的 `trial-007`~`trial-011` 未单独重跑 `PeftConfig` 探测，但 5 份 `adapter_config.json` 与实测通过的 8 份同构（`r=8`、`lora_alpha=16`、12 个 `target_modules`、`peft_version=0.21.2`），且基座字段已从训练机本地路径改写为公开 id `internlm/Intern-Decision-4B`。

### 已知发布缺陷（已修）

1. 模型卡原写 `torch_dtype=torch.bfloat16`，transformers 5.15.1 的 `from_pretrained` 已无此参数 → 改为 `dtype=` 并注明版本分界。
2. 首版验证脚本手写加载与下标切片，首次运行崩在 `logits[candidates].softmax(-1)[1].item()`（`CUDA error: device-side assert triggered`），未入库即被覆盖，**根因未定位**；现脚本改为调用训练仓自己的 `train.runtime`/`short_eval.encode`/`data.score`，并整体包 `torch.no_grad()`。

---

## 五、仍未完成，需要你决定或操作

### 1. GitHub LFS 额度未真正释放（需你操作）

`gh repo delete` 失败：`HTTP 403: Must have admin rights to Repository.`，当前 token scopes 只有 `gist, read:org, repo, workflow`，缺 `delete_repo`。

```bash
gh auth refresh -h github.com -s delete_repo
# 然后删仓重建（本地已有 /tmp/rsi-pre-migration.bundle 备份）
gh repo delete niuwoai/mingjue-data --yes
gh repo create niuwoai/mingjue-data --private
git remote set-url origin git@github.com:niuwoai/mingjue-data.git
git push -u origin main
```

需要说清：**这一步只是回收额度，不是修复功能**。当前推送正常（本次 force push 上传 156 个对象 358 MB 成功），未被额度阻断。删仓会丢掉旧 commit 上的 LFS 存储计费，但 GitHub 侧实际回收数字**我无法验证**（无公开 API 查 LFS 用量）。

### 2. q4 单机权重已补档（原缺口已闭合）

历史归档原先只覆盖"曾进过 git 的 8 份 adapter"，q4 上还有 5 份从未入过 git、单机唯一副本的权重。已全部拉回并推入同一归档仓库：

| subfolder | 训练机来源（q4） | 大小 | `training_engine_version` | 权重 sha256（远端 = 本地） |
|---|---|---:|---|---|
| `trial-007` | `rsi-tool-gate-shell-scale/runs/trial-007` | 65,003,848 | 0.9.0 | `545b3fdd…a1816a5` |
| `trial-008` | `rsi-tool-gate-shell-scale-v8/runs/trial-008` | 65,003,848 | 0.9.1 | `8220179c…f6b7b1` |
| `trial-009` | `rsi-tool-gate-shell-dialect-v9/runs/trial-009` | 65,003,848 | 0.11.0 | `dadf70f1…42c8ed9b` |
| `trial-010` | `rsi-tool-gate-shell-literal-v10/runs/trial-010` | 65,003,848 | 0.14.0 | `a4f6ef50…bfa94b6` |
| `trial-011` | `rsi-tool-gate-shell-auth-v11/runs/trial-011` | 65,003,848 | 0.18.0 | `81562d00…59bdcd8` |

合计 313 MB。核验方式：拉回后本地 `shasum -a 256` 与上传后 HF `paths-info` 返回的 LFS `oid` 逐一对齐，5/5 相同。

**按 trial 号命名、不绑定实验版本号**：这 5 份对应 v0.7.0~v0.12.0 区间，但仓库交付物中缺少能一一锚定版本号的确证，强行标版本号会制造错误的版本真相。表中的 `training_engine_version` 直接取自各 `runs/` 下的 `model-provenance.json`，不是推测。

### 3. 本地 `.git/lfs` 仍占 1.5 GB

权重对象已被历史移除，成了不可达对象。`git lfs prune` 可以回收（权重已在 HF，工作树里没有权重文件，prune 不影响任何在用文件）。属于破坏性操作，未执行，等你确认。

### 4. 训练相关的实质未完成项

- 21 条误拦/漏放的人工复核，尤其 2 条漏放是否为标签噪声（`SHT4-write_shell_holdout-5-0` 优先）。
- 300~500 条人工金标集：唯一能让"能否进入影子运行"脱离合成标签的路径。
- `verify_hf_publish.py` 的 CUDA 崩溃根因未定位（已用替代实现绕过，非修复）。

---

## 六、明确未证明的事

1. **100% 准确率不等于会识别真实风险。** 1,200 条锁定测试的标签由策略规则生成，满分只证明学会了这批构造规则。
2. **归因是观察性的，不是受控实验。** "模板缺失导致误拦" 是从训练集分布对照推出的，没有做补数据再训的对照。
3. **没有人工金标。** 所有版本 `human_gold=0`、`production_qualified=false`，这一轮不产生生产可用结论。
4. **子集样本极小。** old15 只有 15 条、old26 只有 26 条，1 条的差异不构成统计结论。
5. **HF 权重只在本机环境验证过。** 其它 CUDA 版本、其它 GPU 架构的复现未验证；模型卡只声明打分口径，未附完整可运行打分脚本，使用者仍需自备 `compile_row`。

---

## 附：证据索引

- 训练与评估报告：`deliverables/2026-10-22/工具调用二分类门控-4B同数据复训-v0.14.0/实验报告.md`（299 行）
- 预注册：同目录 `实验预注册.md`
- 逐行预测：`trial-014/regression-predictions-adapter.jsonl`、`trial-014/regression-predictions-base.jsonl`
- 错误明细：`trial-014/regression-errors.json`
- HF 复现：`trial-014/hf-publish-verification.json`、`trial-014/hf-verify.log`
- 权重台账：`模型权重归档.md`
- 迁移前全量备份：`/tmp/rsi-pre-migration.bundle`（10 个 commit，1.6 MB，临时目录，建议转存）
