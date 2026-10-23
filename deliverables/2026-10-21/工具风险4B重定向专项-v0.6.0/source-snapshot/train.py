#!/usr/bin/env python3
"""One-epoch, full-vocabulary decision-position LoRA trial on real weak labels."""
import argparse
import json
import math
import random
import sys
import time
from pathlib import Path
from data import SPLITS, digest, evaluate, load_data, metrics, save, score
from balance import balanced_order

VERSION = "0.8.0"
SEED = 20261021
BASE_REVISION = "8797836c65fc91a2435b1fb6850b5f0aabd75cc3"


def runtime(args):
    import torch
    from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration
    from peft import LoraConfig, TaskType, get_peft_model, PeftModel
    sys.path.insert(0, str(args.upstream))
    from src.inputs.schema import compile_row
    if args.mode != "audit":
        manifest = json.loads((args.data / "manifest.json").read_text())
        accepted = manifest.get("labels") == 10000 or manifest.get("experiment") in (
            "balanced_policy_augmentation_v2", "disk_safety_4000_v3", "short_context_4000_v4", "shell_redirect_6000_v6")
        if not accepted or manifest.get("human_verified_rows") != 0:
            raise ValueError("Expected a frozen weak-label or policy-augmentation manifest")
        if (args.data / "AUDIT_ONLY_NOT_LABELS.txt").exists():
            raise ValueError("Placeholder audit data cannot be used for training")
        for split in SPLITS:
            if digest(args.data / (split+".jsonl")) != manifest["splits"][split]["sha256"]:
                raise ValueError("Dataset differs from frozen manifest: "+split)
    random.seed(SEED)
    torch.manual_seed(SEED)
    torch.cuda.manual_seed_all(SEED)
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    if "<decision>" not in tokenizer.get_added_vocab():
        raise ValueError("Missing native decision token")
    data = load_data(args, tokenizer, compile_row, torch)
    if args.mode == "audit":
        print("TOKENIZATION_AUDIT_COMPLETE", flush=True)
        return torch, tokenizer, None, data
    base = Qwen3_5ForConditionalGeneration.from_pretrained(args.model, dtype=torch.bfloat16,
        attn_implementation="sdpa", local_files_only=True).to("cuda")
    if args.mode == "verify":
        model = PeftModel.from_pretrained(base, args.run / "adapter")
    else:
        targets = [name for name, module in base.named_modules()
                   if "language_model.layers." in name and isinstance(module, torch.nn.Linear)]
        if not targets:
            raise ValueError("No native language Linear layers")
        model = get_peft_model(base, LoraConfig(task_type=TaskType.CAUSAL_LM,
            r=8, lora_alpha=16, lora_dropout=0.05, target_modules=targets))
        save(args.run / "lora-modules.json", targets)
    model.config.use_cache = False
    return torch, tokenizer, model, data


def alignment_audit(model, item, torch, run):
    model.eval()
    batch = {k: v.to("cuda") for k, v in item["batch"].items()}
    labels = torch.full_like(batch["input_ids"], -100)
    labels[0, item["position"].item()+1] = item["target"].to("cuda")
    with torch.no_grad():
        manual = torch.nn.functional.cross_entropy(score(model, item), item["target"].to("cuda")).item()
        reference = model(**batch, labels=labels, use_cache=False).loss.item()
    save(run / "alignment.json", {"id": item["id"], "manual": manual, "causal_reference": reference,
                                  "difference": abs(manual-reference), "answer_in_input": False})
    if abs(manual-reference) > 0.001:
        raise ValueError("Misaligned target loss")


def checkpoint(args, model, tokenizer, optimizer, torch, step, microsteps):
    model.save_pretrained(args.run / "adapter")
    tokenizer.save_pretrained(args.run / "tokenizer")
    torch.save({"optimizer": optimizer.state_dict(), "optimizer_step": step, "microsteps": microsteps,
                "cpu_rng": torch.get_rng_state(), "cuda_rng": torch.cuda.get_rng_state_all()},
               args.run / "training-state.pt")


def train(args, torch, tokenizer, model, data):
    train_items = data["train"]
    available_train_rows = len(train_items)
    if args.max_train_rows and not args.balanced_draws and len(train_items) > args.max_train_rows:
        positive_items = [i for i in train_items if i["label"]]
        negative_items = [i for i in train_items if not i["label"]]
        if len(positive_items) >= args.max_train_rows:
            raise ValueError("Trial cap cannot retain all review positives and negatives")
        random.Random(SEED).shuffle(negative_items)
        train_items = positive_items + negative_items[:args.max_train_rows-len(positive_items)]
    positives = sum(i["label"] for i in train_items)
    if positives == 0 or positives == len(train_items):
        raise ValueError("Cannot train a decision gate without both target classes")
    alignment_audit(model, train_items[0], torch, args.run)
    evaluation_splits = SPLITS[1:]
    before = {}
    for split in evaluation_splits:
        before[split] = evaluate(model, data[split], torch)
        save(args.run / ("base-"+split+".json"), before[split])
        print(json.dumps({"base_evaluated": split, "rows": len(before[split])}), flush=True)
    parameters = [p for p in model.parameters() if p.requires_grad]
    if any("lora_" not in name for name, p in model.named_parameters() if p.requires_grad):
        raise ValueError("Unexpected base/vision parameter trainable")
    optimizer = torch.optim.AdamW(parameters, lr=5e-5)
    initial_adapter = [p.detach().cpu().clone() for p in parameters]
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model.enable_input_require_grads()
    model.train()
    order = list(range(len(train_items)))
    random.Random(SEED).shuffle(order)
    if args.balanced_draws:
        order = balanced_order(train_items, args.balanced_draws, args.accumulation, SEED)
    save(args.run / "training-order.json", [train_items[i]["id"] for i in order])
    positive_weight = 1.0 if args.balanced_draws else min(20.0, (len(train_items)-positives)/positives)
    normalizer = (len(train_items)-positives+positives*positive_weight)/len(train_items)
    trace, optimizer_step, start = [], 0, time.perf_counter()
    # First backward uses the longest training record; discard these gradients.
    longest = max(train_items, key=lambda i: i["length"])
    probe = torch.nn.functional.cross_entropy(score(model, longest), longest["target"].to("cuda"))
    probe.backward()
    optimizer.zero_grad(set_to_none=True)
    save(args.run / "memory-probe.json", {"id": longest["id"], "tokens": longest["length"],
         "peak_reserved_bytes": torch.cuda.max_memory_reserved(), "backward_passed": True})
    for begin in range(0, len(order), args.accumulation):
        indices = order[begin:begin+args.accumulation]
        optimizer.zero_grad(set_to_none=True)
        losses = []
        tick = time.perf_counter()
        for index in indices:
            item = train_items[index]
            loss = torch.nn.functional.cross_entropy(score(model, item), item["target"].to("cuda"))
            weight = (positive_weight if item["label"] else 1.0)/normalizer
            (loss*weight/len(indices)).backward()
            losses.append(loss.item())
        norm = torch.nn.utils.clip_grad_norm_(parameters, 1.0)
        if not all(math.isfinite(v) for v in losses) or not math.isfinite(norm.item()):
            raise ValueError("Non-finite loss/gradient")
        optimizer.step()
        optimizer_step += 1
        torch.cuda.synchronize()
        row = {"optimizer_step": optimizer_step, "microsteps": begin+len(indices),
               "mean_full_vocab_loss": sum(losses)/len(losses), "gradient_norm": norm.item(),
               "seconds": time.perf_counter()-tick}
        trace.append(row)
        with (args.run / "trace.jsonl").open("a") as handle:
            handle.write(json.dumps(row)+"\n")
        print(json.dumps(row), flush=True)
        if optimizer_step % 50 == 0:
            checkpoint(args, model, tokenizer, optimizer, torch, optimizer_step, row["microsteps"])
    checkpoint(args, model, tokenizer, optimizer, torch, optimizer_step, len(order))
    updated_tensors = sum(not torch.equal(before, parameter.detach().cpu())
                          for before, parameter in zip(initial_adapter, parameters))
    if not updated_tensors:
        raise ValueError("No adapter tensor updated")
    trained_seconds = time.perf_counter()-start
    after = {}
    for split in evaluation_splits:
        after[split] = evaluate(model, data[split], torch)
        save(args.run / ("adapter-"+split+".json"), after[split])
    # Threshold selection uses only the reserved threshold-validation split.
    selection = after["threshold_validation"]
    threshold = 0.5
    if not args.balanced_draws and min(sum(r['label'] == label for r in selection) for label in (0, 1)) >= 20:
        threshold = max([i/100 for i in range(5, 96, 5)], key=lambda t: metrics(selection, t)["macro_f1"])
    summary = {"version": VERSION, "base_revision": BASE_REVISION, "epochs": None if args.balanced_draws else 1,
               "available_train_rows": available_train_rows, "train_rows": len(order),
               "trial_sampling": "balanced accumulation batches with shuffled cyclic class pools" if args.balanced_draws else "positive retention plus seeded negatives",
               "unique_rows_seen": len(set(order)), "positive_draws": sum(train_items[i]['label'] for i in order),
               "unique_positive_rows_seen": len({i for i in order if train_items[i]['label']}),
               "balanced_draws": args.balanced_draws,
               "max_train_rows": args.max_train_rows, "train_positive_rows": positives, "positive_weight": positive_weight,
               "gradient_accumulation": args.accumulation, "optimizer_steps": optimizer_step,
               "trainable_parameters": sum(p.numel() for p in parameters), "training_seconds": trained_seconds,
               "updated_adapter_tensors": updated_tensors,
               "peak_reserved_bytes": torch.cuda.max_memory_reserved(), "gpu": torch.cuda.get_device_name(),
               "seed": SEED, "max_length": args.max_length, "threshold": threshold,
               "threshold_selection": "fixed 0.5 preregistered for balanced experiment; legacy tuning requires at least 20 examples per class",
               "before": {s: metrics(v) for s, v in before.items()},
               "after_fixed_0_5": {s: metrics(v) for s, v in after.items()},
               "after_selected_threshold": {s: metrics(v, threshold) for s, v in after.items()},
               "always_allow": {s: metrics([dict(r, probability=0.0) for r in v]) for s, v in after.items()},
               "human_gold": False, "production_qualified": False,
               "data_manifest_sha256": digest(args.data / "manifest.json")}
    save(args.run / "metrics.json", summary)
    print(json.dumps(summary), flush=True)


def verify(args, torch, model, data):
    reference = json.loads((args.run / "adapter-locked_test_candidate.json").read_text())
    actual = evaluate(model, data["locked_test_candidate"], torch)
    if [r["id"] for r in actual] != [r["id"] for r in reference]:
        raise ValueError("Reload evaluation IDs changed")
    difference = max((abs(a["probability"]-b["probability"]) for a,b in zip(actual,reference)), default=0)
    save(args.run / "reload-verification.json", {"fresh_process": True, "rows": len(actual),
         "max_probability_difference": difference, "tolerance": 0.001, "passed": difference <= 0.001})
    if difference > 0.001:
        raise ValueError("Fresh-process reload mismatch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("model", "upstream", "data", "run"):
        parser.add_argument("--"+name, type=Path, required=True)
    parser.add_argument("--mode", choices=("audit", "train", "verify"), default="train")
    parser.add_argument("--max-length", type=int, default=1536)
    parser.add_argument("--accumulation", type=int, default=16)
    parser.add_argument("--max-train-rows", type=int, default=0)
    parser.add_argument("--balanced-draws", type=int, default=0)
    args = parser.parse_args()
    args.run.mkdir(parents=True, exist_ok=True)
    if args.mode == "train" and ((args.run / "trace.jsonl").exists() or (args.run / "metrics.json").exists()):
        raise ValueError("Refusing to overwrite an existing training run")
    torch, tokenizer, model, data = runtime(args)
    if args.mode == "train":
        train(args, torch, tokenizer, model, data)
    elif args.mode == "verify":
        verify(args, torch, model, data)
