# `verify_hf_publish.py` CUDA device-side assert 根因

日期：2026-10-23
脚本：`/home/ml-data/rsi-tool-gate-shell-auth-4b-v14/verify_hf_publish.py`（旧版，已被覆盖）
主机：q4（`ssh -p 50022 root@h2.niuwoai.com`）

## 结论

不是显存不足、不是驱动问题、不是 bf16 数值问题，是**索引打错了维度**：拿符号 token id 去索引了长度为 1 的 batch/position 维，而不是 vocab 维。属于纯代码缺陷，与模型和硬件无关。

缺了一次 squeeze：`logits[position]` 里的 `position` 是**单元素 tensor**（`tensor([318])`，shape `(1,)`），切片后前导维被保留，得到 `(1, 152064)`；随后的 `logits[candidates]` 取的是**第 0 维**，而候选 token id 是 32 / 33，对长度 1 的维越界。

## 逐步时序

```
position      = tensor([318])   shape=(1,)  dtype=int64
candidates    = [32, 33]        # <decision> 之后的 gate 符号 token
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
`data.py:61` 的 `score()` 用 `logits_to_keep=item["position"]`，logits 形状是 `(batch, len(position), vocab)`；调用方取 `[0, item["candidates"]]`，第 1 维才是 vocab。手搓版本丢掉了这个语义，自己 `logits[position]` 手工切片就多留了一维。

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
- **推断**：旧版 `review_probability` 的确切源码排布。文件已被覆盖且无备份，是依据 traceback 插入符与函数签名 `(model, batch, position, candidates, torch)` 重建的；插入符证明坏操作是 `logits[candidates]`，这一条不依赖推断。
- **未做**：未改动现行脚本（保持 13:34 产物与文件一致）。如果要防同类复发，最小硬化是在 `score` 返回值上加一句 `logits.dim() == 2` 断言，代价是必须重跑一次才能让产物与文件重新对齐。
