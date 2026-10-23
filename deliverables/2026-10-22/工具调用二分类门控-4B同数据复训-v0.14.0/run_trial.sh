#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ml-data/rsi-tool-gate-shell-auth-4b-v14
PYTHON=/home/ml-data/rsi-smoke/venv/bin/python
MODEL=/home/ml-data/rsi-smoke/model-4b
UPSTREAM=/home/ml-data/rsi-smoke/upstream
DATA="$ROOT/dataset"
RUN="$ROOT/runs/trial-014"
PREVIOUS=/home/ml-data/rsi-tool-gate-shell/runs/trial-006

systemctl stop llama-qwen38-cuda.service
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false

cd "$ROOT"
"$PYTHON" shell_4b_scale.py --mode audit --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16 --expected-train-rows 28000 --balanced-draws 28000
"$PYTHON" shell_4b_scale.py --mode train --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16 --expected-train-rows 28000 --balanced-draws 28000
"$PYTHON" shell_4b_scale.py --mode verify --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --max-length 1536 --accumulation 16 --expected-train-rows 28000 --balanced-draws 28000
"$PYTHON" evaluate_regression.py --model "$MODEL" --upstream "$UPSTREAM" --data "$DATA" --run "$RUN" --previous-run "$PREVIOUS" --max-length 1536 --model-name "Intern-Decision-4B"
