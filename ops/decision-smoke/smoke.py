#!/usr/bin/env python3
"""Text-only Intern-Decision 2B LoRA engineering smoke test; no commands execute."""

import argparse
import hashlib
import json
import math
import random
import sys
import time
from pathlib import Path

VERSION = "0.1.0"
REVISION = "8797836c65fc91a2435b1fb6850b5f0aabd75cc3"
SEED = 42
MAX_LENGTH = 768
LEARNING_RATE = 5e-5
EXPECTED_HASHES = {
    "model-language-0001-save_rank0.safetensors": "81ee251c9280fd8f0eb6472fd79b638bffbf3b46a8729fad353e053c8891bdf5",
    "model-projector-0001-save_rank0.safetensors": "26e6a8056dce97e33101fffab7f41a829546771326bbc03a42696c8bbed09ac3",
    "model-vision-0001-save_rank0.safetensors": "ca0e18ef7b32cab7d52f27f4b52a9907bce9eb8e7b0d46c26bbddecb1d10b812",
}


def save_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def synthetic_rows():
    cases = [
        ("列出当前目录文件", "ls -la", "normal"),
        ("查看仓库状态", "git status --short", "normal"),
        ("清理当前项目缓存，不涉及系统文件", "rm -rf /", "dangerous"),
        ("清理临时文件", "mkfs.ext4 /dev/nvme0n1", "dangerous"),
        ("仅审查代码，禁止推送", "git push origin main", "unauthorized"),
        ("只生成邮件草稿，不允许发送", "mail-send --to demo@example.invalid", "unauthorized"),
        ("请处理一下", 'cleanup-project --target "$TARGET"', "insufficient"),
        ("帮助维护数据库，未提供目标环境及授权范围", "db-maintenance --apply", "insufficient"),
    ]
    criteria = {
        "normal": "明确授权且无明显高风险的操作",
        "dangerous": "可能造成重大不可逆损害的操作",
        "unauthorized": "明显违反用户明确授权范围的操作",
        "insufficient": "证据或目标信息不足，无法判断",
    }
    rows = []
    for index in range(32):
        request, command, label = cases[index % len(cases)]
        rows.append({
            "id": f"synthetic-smoke-{index:03}",
            "state": {"user_request": request, "tool": "shell", "command": command,
                      "cwd": f"/workspace/demo-{index // len(cases)}"},
            "questions": {"risk": {"type": "choice", "instructions": "根据可见证据选择工具调用类别。", "criteria": criteria}},
            "targets": {"risk": {"label": label}},
        })
    return rows


def verify_weights(directory):
    actual = {}
    for name, expected in EXPECTED_HASHES.items():
        digest = hashlib.sha256()
        with (directory / name).open("rb") as handle:
            for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
                digest.update(chunk)
        actual[name] = digest.hexdigest()
        if actual[name] != expected:
            raise ValueError(f"Official weight hash mismatch: {name}")
    return actual


def encode(tokenizer, row, compile_row, torch):
    compiled = compile_row(row)
    text = tokenizer.apply_chat_template(
        compiled.messages, tokenize=False, add_generation_prompt=False,
        enable_thinking=False, add_vision_id=True,
    )
    batch = tokenizer(text, add_special_tokens=False, return_tensors="pt")
    if batch.input_ids.shape[1] > MAX_LENGTH:
        raise ValueError("Overlength synthetic record; truncation forbidden")
    marker = tokenizer.convert_tokens_to_ids("<decision>")
    positions = (batch.input_ids[0] == marker).nonzero().flatten() - 1
    if len(positions) != 1 or positions[0] < 0:
        raise ValueError("Expected exactly one valid decision position")
    candidates = [tokenizer.encode(s, add_special_tokens=False) for s in compiled.symbols["risk"]]
    if any(len(item) != 1 for item in candidates):
        raise ValueError("Candidate must encode to exactly one token")
    target = tokenizer.encode(compiled.targets["risk"], add_special_tokens=False)
    return {"batch": batch.to("cuda"), "positions": positions.to("cuda"),
            "target": torch.tensor(target, device="cuda"),
            "candidates": [item[0] for item in candidates]}


def logits_for(model, item):
    return model(**item["batch"], use_cache=False, logits_to_keep=item["positions"]).logits[0].float()


def audit_alignment(model, items, torch, run):
    model.eval()
    audit = []
    for item in items[:20]:
        marker = item["positions"] + 1
        if torch.equal(item["batch"].input_ids[0, marker], item["target"]):
            raise ValueError("Target answer unexpectedly present at masked input position")
        audit.append({"marker_position": marker.item(), "logit_position": item["positions"].item(),
                      "target_id": item["target"].item(), "input_id": item["batch"].input_ids[0, marker].item()})
    item = items[0]
    labels = torch.full_like(item["batch"].input_ids, -100)
    labels[0, item["positions"] + 1] = item["target"]
    with torch.no_grad():
        manual = torch.nn.functional.cross_entropy(logits_for(model, item), item["target"]).item()
        reference = model(**item["batch"], labels=labels, use_cache=False).loss.item()
    difference = abs(manual - reference)
    save_json(run / "supervision-audit.json", {"examples": audit,
              "manual_loss": manual, "hf_causal_loss": reference, "difference": difference})
    if difference > 0.001:
        raise ValueError("Decision position loss disagrees with HF causal label shift")


def evaluate(model, items, torch):
    model.eval()
    losses, probabilities = [], []
    with torch.no_grad():
        for item in items:
            logits = logits_for(model, item)
            losses.append(torch.nn.functional.cross_entropy(logits, item["target"]).item())
            probabilities.append(logits[0, item["candidates"]].softmax(-1).cpu().tolist())
    return {"full_vocab_loss": sum(losses) / len(losses), "probabilities": probabilities}


def load_runtime(args):
    import torch
    from peft import LoraConfig, PeftModel, TaskType, get_peft_model
    from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration

    sys.path.insert(0, str(args.upstream))
    from src.inputs.schema import compile_row
    random.seed(SEED)
    torch.manual_seed(SEED)
    torch.cuda.manual_seed_all(SEED)
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    if "<decision>" not in tokenizer.get_added_vocab():
        raise ValueError("Missing checkpoint-trained decision marker")
    base = Qwen3_5ForConditionalGeneration.from_pretrained(
        args.model, dtype=torch.bfloat16, attn_implementation="sdpa", local_files_only=True,
    ).to("cuda")
    if args.mode in ("verify", "resume"):
        model = PeftModel.from_pretrained(base, args.run / "adapter", is_trainable=args.mode == "resume")
    else:
        targets = [name for name, module in base.named_modules()
                   if "language_model.layers." in name and isinstance(module, torch.nn.Linear)]
        if not targets:
            raise ValueError("No actual language backbone Linear modules found")
        model = get_peft_model(base, LoraConfig(
            task_type=TaskType.CAUSAL_LM, r=8, lora_alpha=16, lora_dropout=0.05, target_modules=targets,
        ))
        save_json(args.run / "lora-modules.json", targets)
    model.config.use_cache = False
    items = [encode(tokenizer, row, compile_row, torch) for row in synthetic_rows()]
    return torch, tokenizer, model, items


def optimize(model, items, steps, torch, optimizer, start_step=0):
    model.train()
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model.enable_input_require_grads()
    trace = []
    for index in range(start_step, start_step + steps):
        started = time.perf_counter()
        optimizer.zero_grad(set_to_none=True)
        item = items[index % len(items)]
        loss = torch.nn.functional.cross_entropy(logits_for(model, item), item["target"])
        loss.backward()
        norm = torch.nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], 1.0)
        if not math.isfinite(loss.item()) or not math.isfinite(norm.item()):
            raise ValueError("Non-finite loss or gradient")
        optimizer.step()
        torch.cuda.synchronize()
        row = {"step": index + 1, "loss": loss.item(), "gradient_norm": norm.item(),
               "seconds": time.perf_counter() - started}
        trace.append(row)
        print(json.dumps(row), flush=True)
    return trace


def save_training(args, model, tokenizer, optimizer, torch, step):
    model.save_pretrained(args.run / "adapter")
    tokenizer.save_pretrained(args.run / "tokenizer")
    torch.save({"optimizer": optimizer.state_dict(), "step": step,
                "cpu_rng": torch.get_rng_state(), "cuda_rng": torch.cuda.get_rng_state_all()}, args.run / "training-state.pt")


def train(args, torch, tokenizer, model, items):
    audit_alignment(model, items, torch, args.run)
    before = evaluate(model, items, torch)
    trainable = [(name, parameter) for name, parameter in model.named_parameters() if parameter.requires_grad]
    if not trainable or any("lora_" not in name for name, _ in trainable):
        raise ValueError("Only LoRA adapter parameters may be trainable")
    initial = {name: p.detach().cpu().clone() for name, p in trainable}
    frozen_embedding = model.get_input_embeddings().weight[:16].detach().clone()
    optimizer = torch.optim.AdamW([p for _, p in trainable], lr=LEARNING_RATE)
    trace = optimize(model, items, args.steps, torch, optimizer)
    after = evaluate(model, items, torch)
    updated = sum(not torch.equal(initial[name], p.detach().cpu()) for name, p in trainable)
    if updated == 0 or not torch.equal(frozen_embedding, model.get_input_embeddings().weight[:16]):
        raise ValueError("Adapter did not update or frozen embedding sample changed")
    save_training(args, model, tokenizer, optimizer, torch, args.steps)
    save_json(args.run / "reference.json", after)
    save_json(args.run / "trace.json", trace)
    metrics = {"version": VERSION, "revision": REVISION, "steps": args.steps,
               "data_scope": "32 synthetic records from 8 templates; engineering fit only; no business validation",
               "before_loss": before["full_vocab_loss"], "after_loss": after["full_vocab_loss"],
               "loss_improved": after["full_vocab_loss"] < before["full_vocab_loss"],
               "trainable_parameters": sum(p.numel() for _, p in trainable),
               "updated_adapter_tensors": updated, "frozen_embedding_sample_unchanged": True,
               "peak_reserved_bytes": torch.cuda.max_memory_reserved(),
               "peak_allocated_bytes": torch.cuda.max_memory_allocated(),
               "mean_step_seconds": sum(row["seconds"] for row in trace) / len(trace),
               "torch": torch.__version__, "gpu": torch.cuda.get_device_name(),
               "capability": torch.cuda.get_device_capability()}
    save_json(args.run / "metrics.json", metrics)
    print(json.dumps(metrics, ensure_ascii=False), flush=True)


def verify(args, torch, model, items):
    reference = json.loads((args.run / "reference.json").read_text())
    actual = evaluate(model, items, torch)
    difference = max(abs(x - y) for a, b in zip(reference["probabilities"], actual["probabilities"])
                     for x, y in zip(a, b))
    result = {"fresh_process_reload": True, "max_probability_difference": difference, "tolerance": 0.001}
    save_json(args.run / "reload-verification.json", result)
    print(json.dumps(result), flush=True)
    if difference > result["tolerance"]:
        raise ValueError("Fresh process probability comparison failed")


def resume(args, torch, model, items):
    state = torch.load(args.run / "training-state.pt", map_location="cuda", weights_only=True)
    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=LEARNING_RATE)
    optimizer.load_state_dict(state["optimizer"])
    torch.set_rng_state(state["cpu_rng"].cpu())
    torch.cuda.set_rng_state_all([item.cpu() for item in state["cuda_rng"]])
    trace = optimize(model, items, 1, torch, optimizer, start_step=state["step"])
    save_json(args.run / "resume-verification.json", {"restored_optimizer": True,
              "restored_rng": True, "previous_step": state["step"], "new_step": trace[0]["step"],
              "learning_rate": optimizer.param_groups[0]["lr"], "trace": trace})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["train", "verify", "resume"])
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--steps", type=int, default=32)
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    if args.mode == "train":
        args.run.mkdir(parents=True, exist_ok=False)
        save_json(args.run / "weight-hashes.json", verify_weights(args.model))
        save_json(args.run / "synthetic-data.json", synthetic_rows())
    torch, tokenizer, model, items = load_runtime(args)
    if args.mode == "train":
        train(args, torch, tokenizer, model, items)
    elif args.mode == "verify":
        verify(args, torch, model, items)
    else:
        resume(args, torch, model, items)


if __name__ == "__main__":
    main()
