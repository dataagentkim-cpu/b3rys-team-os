#!/usr/bin/env bash
# 멤버 세션·프로세스 용량 — ★임계값과 세는 법을 한 곳에만 둔다.★ source 해서 쓴다.
#
# 왜 한 파일인가: 막는 쪽(기동 직전)과 세는 쪽(주기 감시)이 임계값을 각자 들고 있으면
#   한쪽만 고쳐져 조용히 갈라진다.
#
# 직접 실행하면 현재 값을 출력한다:  bash capacity-check.sh

# ★tmux 경로는 부르는 쪽과 같은 것을 써야 한다.★ 다른 바이너리를 잡으면 다른 서버를 보게 되고,
#   그러면 세션이 0 으로 세어져 ★상한이 조용히 풀린다.★ 그래서 순서를 고정한다:
#   이미 정해진 TMUX_BIN > PATH 의 tmux > 기본 설치 경로.
if [ -z "${TMUX_BIN:-}" ]; then
  if command -v tmux >/dev/null 2>&1; then TMUX_BIN="$(command -v tmux)"
  else TMUX_BIN="$HOME/.local/bin/tmux"; fi
fi
CLAUDE_BIN_PATH="${CLAUDE_BIN_PATH:-$HOME/.local/bin/claude}"

# ─── 임계값 ────────────────────────────────────────────────────────────────
# 멤버 세션 상한. 근거: 세션 1개 = claude 1 + MCP bun 2 이고, 참조 머신(16GB/10코어)에서
#   claude 세션당 RSS 는 평균 323MB(7개 합 2,260MB)였다. 323MB × 9 ≈ 2.9GB 로
#   b3os 몫을 3GB 이내에 묶는다. 그 머신은 세션 7개 시점에 이미 load average 가
#   코어 수를 넘고 swap 을 75% 쓰고 있었다 — 넉넉히 잡을 근거가 없다.
B3OS_MAX_MEMBER_SESSIONS="${B3OS_MAX_MEMBER_SESSIONS:-9}"

# 주기 감시가 하루에 자동 제출할 수 있는 최대 건수(멤버 1명 기준).
#   자동 제출은 "Enter 가 먹지 않은 예외" 라 드물어야 한다. 1인이 하루 6건을 넘으면
#   원인이 따로 있다고 보고 멈춘다.
B3OS_STUCK_MAX_SUBMITS_PER_DAY="${B3OS_STUCK_MAX_SUBMITS_PER_DAY:-6}"

# 같은 문장을 다시 제출해도 되는 횟수. 같은 문장이 그대로 남아 있다는 것은 그 문장이
#   안 먹힌다는 뜻이고, 또 보내도 결과는 같다.
B3OS_STUCK_MAX_SAME_LINE="${B3OS_STUCK_MAX_SAME_LINE:-1}"

# ─── 셀 수 있는 상태인가 ───────────────────────────────────────────────────
# ★못 세는 것과 0 인 것은 다르다.★ 구분하지 않으면 tmux 를 못 찾았을 때 세션 0 으로
#   읽혀 상한이 통과해 버린다. 부르는 쪽이 이것을 먼저 물어야 한다.
b3os_capacity_usable() { [ -x "$TMUX_BIN" ] || command -v "$TMUX_BIN" >/dev/null 2>&1; }

# ─── 세는 법 ───────────────────────────────────────────────────────────────
# ★프로세스 수를 직접 세지 않는다.★ 참조 머신 실측에서 comm 이 claude 인 프로세스는
#   12개였지만 멤버 세션은 7개였고 5개는 에디터 확장이었다. `pgrep -fl claude` 는 82개를
#   준다(경로에 claude 가 든 것 전부). 그래서 세션 수를 1차 카운터로 두고, 프로세스는
#   "그 세션에서 파생된 것만" 센다.
b3os_member_sessions() { "$TMUX_BIN" ls 2>/dev/null | grep -c '^claude-' || true; }

b3os_pane_pids() {
  "$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null | grep '^claude-' | while read -r s; do
    "$TMUX_BIN" list-panes -t "$s" -F '#{pane_pid}' 2>/dev/null
  done | sort -u
}

# 고아 claude = 실행 경로가 멤버용인데 어느 pane 에도 속하지 않는 것.
#   ★죽이지 않는다★ — 이 판정식이 틀리면 살아있는 멤버를 죽인다. 세기만 한다.
b3os_orphan_claude_pids() {
  local panes all
  panes=$(b3os_pane_pids)
  all=$(ps -Ao pid,comm | awk -v p="$CLAUDE_BIN_PATH" '$2==p {print $1}' | sort -u)
  comm -13 <(printf '%s\n' "$panes") <(printf '%s\n' "$all")
}

# 멤버 세션 1개당 MCP bun 이 2개, 그리고 서버 자신이 2개(bun run start · index.ts).
b3os_bun_expected() { echo $(( $(b3os_member_sessions) * 2 + 2 )); }
b3os_bun_actual()   { ps -Ao pid,comm | awk '$2 ~ /\/bun$|^bun$/' | wc -l | tr -d ' '; }
b3os_bun_excess()   { echo $(( $(b3os_bun_actual) - $(b3os_bun_expected) )); }

# 세션을 하나 더 띄워도 되는가. ★이미 있는 세션의 재시작에는 쓰지 않는다★ — 수가 안 는다.
b3os_session_slot_available() {
  b3os_capacity_usable || return 0   # 못 세면 막지 않는다. 부르는 쪽이 사실을 출력한다.
  [ "$(b3os_member_sessions)" -lt "$B3OS_MAX_MEMBER_SESSIONS" ]
}

b3os_capacity_report() {
  if ! b3os_capacity_usable; then
    echo "용량을 셀 수 없습니다 — tmux 를 찾지 못했습니다($TMUX_BIN)"
    return 0
  fi
  local s o b
  s=$(b3os_member_sessions)
  o=$(b3os_orphan_claude_pids | grep -c . || true)
  b=$(b3os_bun_excess)
  echo "멤버 세션 $s / 상한 $B3OS_MAX_MEMBER_SESSIONS"
  echo "고아 claude $o (상한 0)"
  echo "bun 초과분 $b (상한 0) — 실제 $(b3os_bun_actual) / 기대 $(b3os_bun_expected)"
  [ "$s" -ge "$B3OS_MAX_MEMBER_SESSIONS" ] && echo "⚠ 세션 상한"
  [ "$o" -gt 0 ] && echo "⚠ 고아 claude $o 개: $(b3os_orphan_claude_pids | tr '\n' ' ')"
  [ "$b" -gt 0 ] && echo "⚠ bun 초과분 $b 개"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then b3os_capacity_report; fi
