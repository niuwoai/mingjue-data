# q4 SSH 隧道探活

版本：0.1.0。运行位置：q4。Python 3 标准库，无额外依赖。

每次检查 q4 本机 SSH 可用性，再从 q4 访问 h2.niuwoai.com:50022，使用 ssh-keyscan 获取 Ed25519 公钥，与 q4 本机公钥精确比较。仅 TCP 连通或收到 SSH 横幅不算通过。

连续三次失败后执行 `systemctl restart edge-cli-q4-ssh-h2.service`；两次恢复尝试至少间隔五分钟。本机 SSH 不可用时跳过隧道重启，避免无效操作。首次检查在开机约九十秒后，之后距上次检查结束约一分钟运行。不会修改隧道认证或 SSH 配置。

安装目录：`/opt/q4-tunnel-watchdog`。服务与定时器：`q4-tunnel-watchdog.service`、`q4-tunnel-watchdog.timer`。状态目录：`/var/lib/q4-tunnel-watchdog`，日志写入 systemd journal。

检查：`systemctl status q4-tunnel-watchdog.timer`；日志：`journalctl -u q4-tunnel-watchdog.service`。暂停探活：`systemctl stop q4-tunnel-watchdog.timer`；永久撤销自启：`systemctl disable --now q4-tunnel-watchdog.timer`。暂停探活不会停止 SSH 隧道。

`--dry-run` 只检查并报告拟采取的动作，不更新恢复计数，不重启服务；会创建状态目录和锁文件。

限制：探活依赖 q4 出站网络、h2 DNS 和 SSH Ed25519 主机公钥；若合法轮换 q4 主机公钥，探活自动读取当前本机公钥。当前没有服务 API，版本号随 JSON 日志暴露。
