# shellcheck shell=bash
# lib-timeout.sh — launchd から走る補助スクリプト共通の打ち切り処理（source して使う）
#
# coreutils の timeout は macOS 標準に無いため自前で持つ。
# 使い方: run_with_timeout <秒> <コマンド> [引数...]
# 返り値: コマンドの終了コード。打ち切った場合は kill -9 の分の 137（128+9）。
#
# コマンドは perl の setpgrp で自分専用のプロセスグループに入れて起動し、打ち切るときは
# グループごと kill -9 する。直接の子だけを kill すると、claude update が起動した
# git / node のような孫プロセスが打ち切り後も走り続ける。
# 見張り役も perl 1 プロセスにして、止めたときに sleep が取り残されないようにする。
#
# 別グループに出したコマンドは、launchd がジョブ停止時（bootout 等）にジョブのプロセス
# グループへ送る kill の対象から外れる。見張り役のほうはそのとき一緒に消えるので、
# 呼び出し元が TERM / HUP で止められたらここでグループを道連れにする（打ち切り無しで
# 走り続ける孤児を残さない）。トラップは戻る前に外す（呼び出し元はトラップを持たない前提）。
run_with_timeout() {
    local seconds cmd_pid killer_pid rc
    seconds="$1"
    shift
    cmd_pid=""
    killer_pid=""
    trap 'if [ -n "${cmd_pid}" ]; then kill -9 -- "-${cmd_pid}" 2>/dev/null; fi; if [ -n "${killer_pid}" ]; then kill "${killer_pid}" 2>/dev/null; fi; exit 143' TERM HUP
    /usr/bin/perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' "$@" &
    cmd_pid=$!
    /usr/bin/perl -e 'sleep $ARGV[0]; kill "KILL", -$ARGV[1]' "${seconds}" "${cmd_pid}" >/dev/null 2>&1 &
    killer_pid=$!
    wait "${cmd_pid}"
    rc=$?
    # 止めた見張り役をここで回収する（回収しないと後で "Terminated: 15" が stderr に出る）
    kill "${killer_pid}" 2>/dev/null
    wait "${killer_pid}" 2>/dev/null
    trap - TERM HUP
    return ${rc}
}
