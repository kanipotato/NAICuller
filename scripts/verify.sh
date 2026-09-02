#!/usr/bin/env bash
# NAICuller の検証をまとめたもの。「検証した」と言うときはこれを通す。
#
# 起動確認はプロセスの有無だけで判定しないこと。ログにエラーが出ていないかも見る
# （別プロジェクトで、プロセスは見つかるのに実際は起動失敗していた例がある）。
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()   { printf '  ✅ %s\n' "$1"; }
ng()   { printf '  ❌ %s\n' "$1"; FAILED=1; }

step "ビルド（警告も許さない）"
BUILD_LOG=/tmp/naiculler-build.log
if swift build >"$BUILD_LOG" 2>&1; then
  WARNS=$(grep -c 'warning:' "$BUILD_LOG")
  if [ "$WARNS" = "0" ]; then ok "build（警告なし）"; else ng "build は通ったが警告 $WARNS 件"; grep 'warning:' "$BUILD_LOG" | head -5; fi
else ng "build 失敗"; grep 'error:' "$BUILD_LOG" | head -10; fi

step "テスト"
TEST_LOG=/tmp/naiculler-test.log
if swift test >"$TEST_LOG" 2>&1; then
  ok "$(grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures' "$TEST_LOG" | tail -1)"
else ng "テスト失敗"; grep -E 'error:|XCTAssert.*failed|failed \(' "$TEST_LOG" | head -10; fi

step "実起動（プロセス生存 かつ ログにエラー無し）"
BIN=.build/debug/NAICuller
if [ ! -x "$BIN" ]; then
  ng "$BIN が無い（先にビルドが必要）"
else
  LOG=/tmp/naiculler-launch.log
  : > "$LOG"
  # 絶対パスで起動する。相対パスで起動すると pgrep -f の絶対パス検索に引っかからず、
  # 実際は動いているのに「起動失敗」と誤判定する。
  ABS_BIN="$(pwd)/$BIN"
  ("$ABS_BIN" >"$LOG" 2>&1 &)
  sleep 6
  PID="$(pgrep -f "$ABS_BIN" | head -1)"
  ERRS="$(grep -icE 'Fatal error|Thread .* Crash|error:' "$LOG")"
  if [ -n "$PID" ] && [ "$ERRS" = "0" ]; then ok "起動確認（pid=$PID・エラー出力なし）"
  else ng "起動失敗（pid=${PID:-なし} / ログのエラー行=$ERRS）"; head -15 "$LOG"; fi
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
fi

step "公開リポ向け: 個人の開発パス混入チェック"
# NAICuller は Public。README・コメント・UI文言に ~/Dev などの実パスを書かない方針。
# gitleaks はこの種のパスを検出しないので別途見る（コード内の既定ルックアップ先は対象外）。
HITS=$(git diff origin/main...HEAD 2>/dev/null | grep -E '^\+' | grep -E '~/Dev|/Users/' | grep -v 'appendingPathComponent' | head -5)
if [ -z "$HITS" ]; then ok "実パスの混入なし"; else ng "実パスが混入している可能性"; printf '%s\n' "$HITS"; fi

printf '\n'
if [ "$FAILED" = "0" ]; then printf '\033[1;32m全チェック通過\033[0m\n'; else printf '\033[1;31m失敗あり\033[0m\n'; fi
exit "$FAILED"
