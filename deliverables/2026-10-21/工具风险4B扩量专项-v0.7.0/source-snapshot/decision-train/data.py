"""Text-only dataset compiler: no historical command is ever executed."""
import hashlib
import json
import math
from pathlib import Path

SPLITS = ("train", "development", "calibration", "threshold_validation", "locked_test_candidate")


def save(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_data(args, tokenizer, compile_row, torch):
    result, report, groups, ids = {}, {}, {}, set()
    for split in SPLITS:
        path = args.data / (split + ".jsonl")
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        items, excluded = [], []
        for row in rows:
            if row["id"] in ids:
                raise ValueError("Duplicate sample ID")
            ids.add(row["id"])
            previous = groups.setdefault(row["group_id"], split)
            if previous != split:
                raise ValueError("Lineage group crosses split boundary")
            compiled = compile_row(row)
            text = tokenizer.apply_chat_template(compiled.messages, tokenize=False,
                add_generation_prompt=False, enable_thinking=False, add_vision_id=True)
            batch = tokenizer(text, add_special_tokens=False, return_tensors="pt")
            length = batch.input_ids.shape[1]
            if length > args.max_length:
                excluded.append({"id": row["id"], "tokens": length, "reason": "overlength_no_truncation"})
                continue
            marker = tokenizer.convert_tokens_to_ids("<decision>")
            positions = (batch.input_ids[0] == marker).nonzero().flatten() - 1
            if len(positions) != 1 or positions.item() < 0:
                raise ValueError("Expected one decision position")
            candidates = [tokenizer.encode(s, add_special_tokens=False) for s in compiled.symbols["gate"]]
            if any(len(c) != 1 for c in candidates):
                raise ValueError("Candidate symbols must be single tokens")
            target = tokenizer.encode(compiled.targets["gate"], add_special_tokens=False)
            if len(target) != 1 or batch.input_ids[0, positions.item()+1] == target[0]:
                raise ValueError("Invalid target or answer leakage")
            items.append({"id": row["id"], "group_id": row["group_id"], "batch": batch,
                          "position": positions, "target": torch.tensor(target),
                          "candidates": [c[0] for c in candidates],
                          "label": int(row["targets"]["gate"]["label"] == "needs_review"), "length": length})
        result[split] = items
        report[split] = {"source_rows": len(rows), "used": len(items), "excluded": excluded,
                         "positives": sum(r["label"] for r in items), "sha256": digest(path),
                         "tokens": sorted(r["length"] for r in items)}
    save(args.run / "data-audit.json", report)
    return result


def score(model, item):
    batch = {k: v.to("cuda") for k, v in item["batch"].items()}
    return model(**batch, use_cache=False, logits_to_keep=item["position"].to("cuda")).logits[0].float()


def metrics(rows, threshold=0.5):
    tp = sum(r["label"] == 1 and r["probability"] >= threshold for r in rows)
    fp = sum(r["label"] == 0 and r["probability"] >= threshold for r in rows)
    fn = sum(r["label"] == 1 and r["probability"] < threshold for r in rows)
    tn = sum(r["label"] == 0 and r["probability"] < threshold for r in rows)
    ratio = lambda a, b: a / b if b else None
    def interval(hits, total):
        if not total:
            return None
        z = 1.959963984540054
        p = hits/total
        center = (p+z*z/(2*total))/(1+z*z/total)
        half = z*math.sqrt(p*(1-p)/total+z*z/(4*total*total))/(1+z*z/total)
        return [max(0, center-half), min(1, center+half)]
    f1_positive = ratio(2*tp, 2*tp+fp+fn)
    f1_negative = ratio(2*tn, 2*tn+fp+fn)
    return {"rows": len(rows), "threshold": threshold, "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "review_recall": ratio(tp, tp+fn), "false_allow_rate": ratio(fn, tp+fn),
            "review_positive_support": tp+fn, "review_recall_wilson_95": interval(tp, tp+fn),
            "false_review_rate": ratio(fp, fp+tn), "accuracy": ratio(tp+tn, len(rows)),
            "macro_f1": ((f1_positive or 0)+(f1_negative or 0))/2,
            "positive_class_absent": tp+fn == 0}


def evaluate(model, items, torch):
    model.eval()
    rows = []
    with torch.no_grad():
        for item in items:
            probability = score(model, item)[0, item["candidates"]].softmax(-1)[1].item()
            rows.append({"id": item["id"], "group_id": item["group_id"],
                         "label": item["label"], "probability": probability})
    return rows
