#!/usr/bin/env bash
# 세션 수 상한 게이트 — ★막아야 할 것을 막고, 막으면 안 되는 것을 안 막는가.★
#
# 이 시험이 지키는 불변식: ★상한을 넘은 상태에서도 재시작은 반드시 복구된다.★
#   기동 스크립트를 부르기 전에 호출부가 tmux kill-session 을 먼저 하는 재시작 경로가
#   있다. 그 경로에서는 스크립트 실행 시점에 세션이 없으므로, 위치로만 판단하면
#   재시작이 새 기동으로 오인돼 상한에 막힌다 — 죽여놓고 못 살리는 상태가 된다.
#
# tmux·bun·claude 는 스텁으로 갈음한다. 실제 세션을 띄우지 않는다.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../src/server/runtimes/claude/start-telegram-channel.sh"
[ -r "$SCRIPT" ] || { echo "기동 스크립트 없음: $SCRIPT"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
bad()  { fail=$((fail+1)); echo "  ❌ $1"; echo "     $2"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
SESS="$ROOT/sessions"; CALLS="$ROOT/calls"

# ── tmux 스텁 ─────────────────────────────────────────────────────────────
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
# 최소 tmux 스텁 — 세션 목록을 파일 하나로 흉내 내고, 호출을 기록한다.
S="${STUB_SESSIONS:?}"; C="${STUB_CALLS:?}"
echo "$*" >> "$C"
cmd="$1"; shift
case "$cmd" in
  ls)
    if [ "${1:-}" = "-F" ]; then cat "$S" 2>/dev/null; else sed 's/$/: 1 windows/' "$S" 2>/dev/null; fi
    exit 0 ;;
  has-session)
    # -t <name> 만 본다. ★종료코드가 이 명령의 답이다★ — 삼키면 안 된다.
    while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { t="$2"; break; }; shift; done
    grep -qx "${t:-}" "$S" 2>/dev/null; exit $? ;;
  kill-session)
    while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { t="$2"; break; }; shift; done
    grep -vx "${t:-}" "$S" > "$S.tmp" 2>/dev/null; mv "$S.tmp" "$S"; exit 0 ;;
  list-panes) echo 10001; exit 0 ;;
  new-session)
    while [ $# -gt 0 ]; do [ "$1" = "-s" ] && { echo "$2" >> "$S"; break; }; shift; done
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/tmux"
for b in bun claude python3; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$b"; chmod +x "$BIN/$b"; done

run_case() {  # $1=세션목록(공백구분) $2=봇이름 $3...=인자/환경
  local list="$1" bot="$2"; shift 2
  : > "$SESS"; : > "$CALLS"
  for s in $list; do echo "$s" >> "$SESS"; done
  local home="$ROOT/home"; rm -rf "$home"
  mkdir -p "$home/.claude/channels/telegram-$bot"
  echo 'TELEGRAM_BOT_TOKEN=stub' > "$home/.claude/channels/telegram-$bot/.env"
  env -i HOME="$home" PATH="$BIN:/usr/bin:/bin" \
      STUB_SESSIONS="$SESS" STUB_CALLS="$CALLS" \
      B3OS_MAX_MEMBER_SESSIONS=3 WORKDIR="$home" CLAUDE_START_NO_STAGGER=1 \
      "$@" bash "$SCRIPT" "$bot" >"$ROOT/out" 2>&1
  echo $?
}
spawned() { grep -q '^new-session' "$CALLS"; }

echo "── A. 상한 초과 + 새 세션 → 막는다 ──"
rc=$(run_case "claude-a claude-b claude-c" newbot)
[ "$rc" = "3" ] && ok "exit 3" || bad "exit 3 이어야 한다" "실제 exit=$rc / $(tail -3 "$ROOT/out")"
spawned && bad "세션을 만들면 안 된다" "new-session 이 호출됐다" || ok "세션 생성 안 됨"

echo "── B. ★상한 초과 + 재시작 신호 → 복구된다★ (이 시험의 핵심) ──"
rc=$(run_case "claude-a claude-b claude-c" newbot B3OS_SESSION_RESTART=1)
[ "$rc" = "3" ] && bad "재시작이 상한에 막혔다 — 죽여놓고 못 살리는 상태" "exit=3" || ok "상한에 막히지 않음 (exit=$rc)"
spawned && ok "세션이 실제로 생성됨" || bad "복구되어야 한다" "new-session 이 없다: $(tail -3 "$ROOT/out")"

echo "── C. 상한 초과 + 기존 세션 + --force → 복구된다 ──"
: > "$SESS"; : > "$CALLS"
rc=$(run_case "claude-a claude-b claude-newbot" newbot; )
# --force 는 run_case 인자로 못 넘기므로 직접 호출
: > "$SESS"; : > "$CALLS"
for s in claude-a claude-b claude-newbot; do echo "$s" >> "$SESS"; done
home="$ROOT/home"; rm -rf "$home"; mkdir -p "$home/.claude/channels/telegram-newbot"
echo 'TELEGRAM_BOT_TOKEN=stub' > "$home/.claude/channels/telegram-newbot/.env"
env -i HOME="$home" PATH="$BIN:/usr/bin:/bin" STUB_SESSIONS="$SESS" STUB_CALLS="$CALLS" \
    B3OS_MAX_MEMBER_SESSIONS=3 WORKDIR="$home" CLAUDE_START_NO_STAGGER=1 bash "$SCRIPT" newbot --force >"$ROOT/out" 2>&1
rc=$?
[ "$rc" = "3" ] && bad "--force 재시작이 상한에 막혔다" "exit=3" || ok "상한에 막히지 않음 (exit=$rc)"
grep -q '^kill-session' "$CALLS" && ok "기존 세션을 정리함" || bad "--force 는 기존 세션을 죽여야 한다" "kill-session 없음"
spawned && ok "세션이 다시 생성됨" || bad "복구되어야 한다" "new-session 없음: $(tail -3 "$ROOT/out")"

echo "── C2. ★kill 뒤에도 여전히 상한 이상인 --force 재시작 → 복구된다★ ──"
# C 는 kill 로 수가 상한 아래로 떨어져 게이트를 안 건드린다. 그래서 스크립트 자신의
# 재시작 표시가 없어도 통과해 버린다. 수가 상한 이상으로 남는 경우가 진짜 경계다.
: > "$SESS"; : > "$CALLS"
for s in claude-a claude-b claude-c claude-newbot; do echo "$s" >> "$SESS"; done
home="$ROOT/home"; rm -rf "$home"; mkdir -p "$home/.claude/channels/telegram-newbot"
echo 'TELEGRAM_BOT_TOKEN=stub' > "$home/.claude/channels/telegram-newbot/.env"
env -i HOME="$home" PATH="$BIN:/usr/bin:/bin" STUB_SESSIONS="$SESS" STUB_CALLS="$CALLS" \
    B3OS_MAX_MEMBER_SESSIONS=3 WORKDIR="$home" CLAUDE_START_NO_STAGGER=1 bash "$SCRIPT" newbot --force >"$ROOT/out" 2>&1
rc=$?
[ "$rc" = "3" ] && bad "kill 뒤 상한 이상이라고 재시작을 막았다 — 죽여놓고 못 살린다" "exit=3" || ok "상한에 막히지 않음 (exit=$rc)"
spawned && ok "세션이 다시 생성됨" || bad "복구되어야 한다" "new-session 없음: $(tail -3 "$ROOT/out")"

echo "── D. 상한 미만 + 새 세션 → 통과한다 ──"
rc=$(run_case "claude-a" newbot)
[ "$rc" = "3" ] && bad "상한 미만인데 막혔다" "exit=3 / $(tail -3 "$ROOT/out")" || ok "통과 (exit=$rc)"
spawned && ok "세션 생성됨" || bad "통과했으면 만들어야 한다" "new-session 없음"

echo "── E. 상한 파일이 없으면 조용히 통과하지 않는다 ──"
rc=$(run_case "claude-a claude-b claude-c" newbot B3OS_CAPACITY_LIB=/nonexistent/capacity-check.sh)
grep -q "용량 상한 파일이 없어" "$ROOT/out" && ok "검사하지 않았다는 사실을 출력함" || bad "사실을 출력해야 한다" "$(tail -3 "$ROOT/out")"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
