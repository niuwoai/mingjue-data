#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ml-data/rsi-tool-gate-shell-auth-v13
PYTHON=/home/ml-data/rsi-smoke/venv/bin/python
MODEL=/home/ml-data/rsi-smoke/model-2b
UPSTREAM=/home/ml-data/rsi-smoke/upstream
DATA="$ROOT/dataset"
RUN="$ROOT/runs/trial-001"
PREVIOUS=/home/ml-data/rsi-tool-gate-shell/runs/trial-006

systemctl stop llama-qwen38-cuda.service
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false

cd "$ROOT"
"$PYTHON" train.py --mode audit --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16
"$PYTHON" train.py --mode train --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16
"$PYTHON" train.py --mode verify --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16
"$PYTHON" evaluate_2b_regression.py --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --previous-run "$PREVIOUS" --max-length 1536

