#!/usr/bin/env bash
# 发布 v0.14.0 门控 adapter 到 Hugging Face Hub。
# 前置：hf auth login（write token），或用 HF_TOKEN 环境变量。
set -euo pipefail

REPO="${REPO:-renlu/intern-decision-4b-tool-gate-v0.14.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hf repos create "$REPO" --type model --public --exist-ok

hf upload "$REPO" "$HERE" . \
  --repo-type model \
  --exclude "upload.sh" \
  --commit-message "v0.14.0: Intern-Decision-4B 工具调用门控 LoRA（同数据 4B 复训）"

echo "已上传：https://huggingface.co/$REPO"
