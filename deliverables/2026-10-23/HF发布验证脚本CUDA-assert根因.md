# `verify_hf_publish.py` CUDA device-side assert 根因

日期：2026-10-23（2026-10-24 补断言硬化）
脚本：`/home/ml-data/rsi-tool-gate-shell-auth-4b-v14/verify_hf_publish.py`
现行版 sha256 `520b4210e6bfe84e0adb7d2f1c13d3bf64c60419c63b1f2dfce6d2ab6b658368`（已加形状断言）；加法前的可用版备份 `verify_hf_publish.py.pre-assert`，sha256 `885fc792ca803118474f577abca9d9cbf95fa5ee031fe838037a193fbadbcc8d`；最初触发崩溃的手搓版无备份
主机：q4（`ssh -p 50022 root@h2.niuwoai.com`）

## 结论

不是显存不足、不是驱动问题、不是 bf16 数值问题，是**索引打错了维度**：拿符号 token id 去索引了长度为 1 的 batch/position 维，而不是 vocab 维。属于纯代码缺陷，与模型和硬件无关。

缺了一次 squeeze：`logits[position]` 里的 `position` 是**单元素 tensor**（`tensor([318])`，shape `(1,)`），切片后前导维被保留，得到 `(1, 152064)`；随后的 `logits[candidates]` 取的是**第 0 维**，而候选 token id 是 32 / 33，对长度 1 的维越界。

## 逐步时序

```
position      = tensor([318])   shape=(1,)  dtype=int64
candidates    = [32, 33]        # gate 符号 token（data.py:43 compiled.symbols["gate"]，各自单 token）
logits[position]              -> shape (1, 152064)   # 第 0 维 = 1，不是 vocab
logits[candidates]            -> 用 32/33 索引第 0 维（大小 1）  ✗ 越界
                               -> 正确目标应是第 1 维（vocab 152064）
```

`candidates` 的正确索引用法是 `[0, candidates]`：第 0 维取 batch，第 1 维取 vocab。

## 为什么报错位置看起来漂移

CUDA 的 device-side assert 是**异步**上报的。原始 traceback 的插入符落在这个表达式的 `.item()` 上：

```python
return logits[candidates].softmax(-1)[1].item()
       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^
```

`.item()` 是第一次强制同步，所以错误在 `.item()` 处抛出，而不是在真正越界的 `logits[candidates]`。插入符位置证明坏操作就是 `logits[candidates]` 本身，不是更早的 `logits[position]`。

## 证据

**1. 旧任务日志的反应**
崩溃前打印了 **0 行**结果（`grep -c '"id"' = 0`）。说明第一条样本就失败 —— 结构性缺陷，不是某条数据触发。日志首行断言即：

```
IndexKernelUtils.cu:19: vectorized_gather_kernel: block: [1,15,0], thread: [154,0,0]
Assertion `ind >=0 && ind < ind_dim_size && "vectorized gather kernel index out of bounds"` failed.
```

`vectorized_gather_kernel` 正是高级索引（`tensor[list]`）走的 kernel，与「拿 list 索引张量」的假设一致。

**2. 形状复现**
在 q4 上用真实 `position` / `candidates` 形状构造同形张量，强制同步后抛出**字面完全一致**的异常：

```
sliced.shape = (1, 152064)
抛出: AcceleratorError | CUDA error: device-side assert triggered
```

同一内核断言也逐字重现：
`vectorized_gather_kernel ... Assertion ind >=0 && ind < ind_dim_size ... index out of bounds`。

**3. 仓库自带路径本来就是对的**
`data.py:61` 的 `score()` 用 `logits_to_keep=item["position"]`，logits 形状是 `(batch, len(position), vocab)`；两个调用方 —— `data.py:95` 与 `short_eval.py` 派生的现行验证脚本 —— 都取 `[0, item["candidates"]]`，第 1 维才是 vocab。手搓版本丢掉了这个语义，自己 `logits[position]` 手工切片就多留了一维。

## 修复与验证

现行脚本改走仓库自己的路径：

```python
adapter_p = score(model, item)[0, item['candidates']].softmax(-1)[1].item()
with model.disable_adapter():
    base_p = score(model, item)[0, item['candidates']].softmax(-1)[1].item()
```

重跑结果 `runs/trial-014/hf-publish-verification.json`（13:34）：`reproduced=True`、`rows_checked=8`、`mismatches=[]`，8 条全部在 1e-6 容差内与记录的预测概率一致，`model_class=Qwen3_5ForConditionalGeneration`。

| id | label | recorded | adapter | base |
|---|---:|---:|---:|---:|
| policy-contrast-005 | 1 | 0.999999 | 0.999999 | 0.977023 |
| SHT4-write_shell_holdout-5-0 | 1 | 0.000203 | 0.000203 | 0.851953 |
| CDX10-00282 | 0 | 0.000017 | 0.000017 | 0.962673 |
| CDX10-00283 | 0 | 0.000066 | 0.000066 | 0.705785 |
| CDX10-00284 | 0 | 0.000085 | 0.000085 | 0.939913 |
| CDX10-03070 | 1 | 0.000804 | 0.000804 | 0.437824 |
| CDX10-05046 | 1 | 0.999998 | 0.999998 | 0.377541 |
| SYN2-kube_scale-0-2 | 1 | 1.000000 | 1.000000 | 0.914901 |

结论：HF 上发布的 adapter 与训练侧记录的预测概率一致，发布链路可用。原 CUDA 崩溃是验证脚本自身的 bug，不影响任何已发布权重。

## 边界

- **已验证**：形状语义、`position` 形状 `(1,)`、`candidates=[32,33]`、越界内核断言逐字复现、旧日志 0 行即崩溃、修正后 8/8 一致。
- **已核对**：`candidates` 由 `data.py:43` 从 `compiled.symbols["gate"]` 编码而来，`data.py:44` 断言每个 gate 符号必须是单 token，因此候选恒为小整数 id。
- **推断**：旧版 `review_probability` 的确切源码排布。文件已被覆盖且无备份，是依据 traceback 插入符与函数签名 `(model, batch, position, candidates, torch)` 重建的；插入符证明坏操作是 `logits[candidates]`，这一条不依赖推断。
- **已做（2026-10-24 断言硬化）**：现行脚本的取概率不再散落在调用方，收敛到 helper `gate_probability(score_fn, model, item, vocab_size)`，进入 softmax 前强制三条断言 —— `logits.shape == (1, vocab_size)`、`0 <= c < vocab_size`（逐候选）、`vocab_size` 取自 `model.config.text_config.vocab_size`（实测 248,320，不是 tokenizer 的 248,078）。负向对照：旧缺陷的 `(1,1,V)`、转置 `(V,1)`、丢 batch 维的 `(V,)`、越界候选四种坏形状全部被拦截（GUARDED），正确形状 PASS（`p=0.993307`）。
- **已重跑**：硬化版在 q4 上跑通，`reproduced: true`、`rows_checked: 8`、`mismatches: []`、`model_class: Qwen3_5ForConditionalGeneration`。产物与 13:34 版逐字段比对（排除 `script_sha256` 类元数据）**完全一致**，已用硬化版产物替换 `runs/trial-014/hf-publish-verification.json`（sha256 `aaadf5ac5cedd098dd4a746a1157f169d92179f119189a5385cebb521af7035a`）。
- **未做**：未把断言做成通用 lint，也未改动 `data.py` / `short_eval.py` 的既有 `[0, candidates]` 调用方 —— 它们本来就对，缺陷只在手搓脚本里。
