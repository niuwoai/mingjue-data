#!/usr/bin/env bash
# v0.15.0 trial-015 收尾链驱动：等 q4 上线 -> verify/regression/gates -> 回传产物
# 幂等：已有 gate-check.json 则跳过执行，只做回传与自检。
set -uo pipefail

Q4=${Q4:-q4}
ROOT=/home/ml-data/rsi-tool-gate-shell-auth-4b-v15
RUN=$ROOT/runs/trial-015
DEST=${DEST:-/Users/rocky/Sites/rsi/deliverables/2026-10-24/工具调用二分类门控-组合配对补强-v0.15.0/trial-015}
WAIT_HOURS=${WAIT_HOURS:-24}

say() { echo "[$(date '+%m-%d %H:%M:%S')] $*"; }

wait_online() {
  local deadline=$(( $(date +%s) + WAIT_HOURS*3600 )) n=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$Q4" true 2>/dev/null; then
      say "q4 上线"; return 0
    fi
    n=$((n+1)); [ $((n % 10)) -eq 0 ] && say "等待 q4 上线（第 $n 次探测）"
    sleep 30
  done
  say "q4 ${WAIT_HOURS} 小时未上线"; return 1
}

wait_online || exit 4

say "== 远端现状 =="
ssh "$Q4" "ls -1 $RUN 2>/dev/null | tr '\n' ' '; echo; pgrep -fa 'post_trial_015|shell_4b_scale|evaluate_regression' | head -5"

say "== 同步 verify 断言 =="
if ssh "$Q4" "test -f $ROOT/train.py"; then
  if ssh "$Q4" "grep -q adapter_application $ROOT/train.py"; then
    say "远端已有 adapter-application 断言"
  else
    scp -q ops/decision-train/train.py "$Q4:$ROOT/train.py" && say "已推送 patched train.py"
    ssh "$Q4" "grep -q adapter_application $ROOT/train.py" || { say "推送后端仍无断言，停止"; exit 5; }
  fi
else
  say "远端 $ROOT/train.py 不存在，停止以免推错目录"; exit 5
fi

if ssh "$Q4" "test -f $RUN/gate-check.json"; then
  say "gate-check.json 已存在，跳过执行"
else
  say "== 启动收尾链 =="
  ssh "$Q4" "cd $ROOT && nohup bash post_trial_015.sh > finalize-015.log 2>&1 & echo LAUNCHED \$!"
fi

say "== 等待 gate-check.json 或链路异常 =="
for i in $(seq 1 360); do
  if ssh "$Q4" "test -f $RUN/gate-check.json" 2>/dev/null; then
    say "gate-check.json 已写出"; break
  fi
  if ssh "$Q4" "grep -qE 'TERMINAL|Traceback|VERIFY_FAIL|no effect' $ROOT/finalize-015.log 2>/dev/null && ! pgrep -f post_trial_015 >/dev/null"; then
    say "链路异常终止"; break
  fi
  sleep 20
done

say "== 回传 trial-015 =="
mkdir -p "$DEST"
rsync -az --info=stats1 "$Q4:$RUN/" "$DEST/" 2>&1 | tail -5
rsync -az --info=stats1 "$Q4:$ROOT/finalize-015.log" "$DEST/" 2>/dev/null

say "== 产物自检 =="
REQ="metrics.json data-audit.json alignment.json trace.jsonl training-order.json model-provenance.json memory-probe.json reload-verification.json adapter-application.json adapter-locked_test_candidate.json base-locked_test_candidate.json regression-comparison.json regression-predictions-adapter.jsonl regression-predictions-base.jsonl gate-check.json adapter/adapter_model.safetensors"
miss=0
for f in $REQ; do
  if [ -s "$DEST/$f" ]; then echo "  OK   $f"; else echo "  MISS $f"; miss=$((miss+1)); fi
done
say "缺失 $miss 项"
[ -s "$DEST/gate-check.json" ] && tail -c 400 "$DEST/gate-check.json"
[ -s "$DEST/adapter-application.json" ] && echo "--- adapter-application ---" && cat "$DEST/adapter-application.json"
exit $(( miss > 0 ))
