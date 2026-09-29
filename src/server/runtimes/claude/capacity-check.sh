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

# ps 표(pid ppid comm)를 한 번만 뜬다. bun 마다 ps 를 부르면 느리고, 도는 동안 프로세스가
# 바뀌어 앞뒤가 안 맞는다. 시험은 B3OS_PS_TABLE_FILE 로 고정된 표를 끼운다.
b3os_ps_table() {
  if [ -n "${B3OS_PS_TABLE_FILE:-}" ]; then cat "$B3OS_PS_TABLE_FILE"
  else ps -Ao pid,ppid,comm; fi
}

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

# 멤버 세션의 MCP bun 만 센다 — 세션 1개당 정확히 2개다.
#
# ★머신의 bun 을 전부 세면 안 되고, "pane 의 자손" 으로도 부족하다.★
#   이전 판은 `전체 bun − (세션수 × 2 + 2)` 였는데, 그 식은 "bun 을 띄우는 것은 멤버
#   세션과 서버뿐" 을 전제한다. 셸에서 `bun test` 를 돌리기만 해도 초과분으로 잡혔다.
#   그렇다고 "부모 사슬이 pane 에 닿는 bun" 으로 바꾸면 여전히 잡힌다 — 멤버가 자기
#   도구로 띄운 셸도 그 pane 의 자손이라, 거기서 돌린 `bun test` 가 같이 걸린다(실측).
#   ★정상 작업을 보고 우는 경고는 반복되면 아무도 보지 않고, 그러면 진짜 누수가 묻힌다.★
#
# 실측한 모양으로 가른다:
#   MCP  : claude(pane) → bun → bun      — 사이가 전부 bun 이다
#   애드혹: claude(pane) → zsh → bun      — 셸이 낀다
# 그래서 ★bun 에서 부모를 따라 올라가며, 중간이 전부 bun 이고 pane 에서 멈추면★ 센다.
#   단 수를 세지 않는다 — "2단까지" 로 적으면 3단 누수가 안 보이고, 그 한 줄을 더하면
#   같은 문제가 4단으로 미뤄질 뿐이다. 실제로 쓰는 기준은 단 수가 아니라 ★사슬에 셸이
#   끼지 않았는가★ 이므로 그것을 그대로 적는다. 셸 목록을 열거할 필요도 없다 —
#   ★bun 이 아니면 탈락★ 이라 무엇이 끼든 같게 처리된다.
#
# ★이 규칙은 위 모양에 묶여 있다.★ MCP 기동 방식이 바뀌어 사이에 bun 아닌 프로세스가
#   끼면 이 카운터는 0 을 센다 — 없는 것을 있다고 하지는 않지만, 있는 누수를 놓치는
#   쪽으로 틀린다. ★그 상태를 보고에서 ⚠ 로 알린다★(아래 b3os_capacity_report).
#   주석은 5분마다 읽히지 않는다.
b3os_member_bun_pids() {
  local panes
  panes=$(b3os_pane_pids)
  [ -n "$panes" ] || return 0
  { printf '%s\n' "$panes"; echo "--"; b3os_ps_table; } | awk '
    $1 == "--" { sep = 1; next }
    !sep { pane[$1] = 1; next }
    { ppid[$1] = $2; isbun[$1] = ($3 ~ /\/bun$|^bun$/) }
    END {
      for (p in ppid) {
        if (!isbun[p]) continue
        c = ppid[p]; d = 0
        while (c != "" && d < 32) {
          if (c in pane) { print p; break }
          if (!isbun[c]) break     # bun 아닌 것이 끼면 우리 것이 아니다
          c = ppid[c]; d++
        }
      }
    }'
}

b3os_bun_expected() { echo $(( $(b3os_member_sessions) * 2 )); }
b3os_bun_actual()   { b3os_member_bun_pids | grep -c . || true; }
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
  local s o a e b
  s=$(b3os_member_sessions)
  o=$(b3os_orphan_claude_pids | grep -c . || true)
  a=$(b3os_bun_actual)
  e=$(b3os_bun_expected)
  b=$(( a - e ))
  echo "멤버 세션 $s / 상한 $B3OS_MAX_MEMBER_SESSIONS"
  echo "고아 claude $o (상한 0)"
  echo "멤버 bun 초과분 $b (상한 0) — 멤버 세션이 낳은 bun $a / 기대 $e"
  [ "$s" -ge "$B3OS_MAX_MEMBER_SESSIONS" ] && echo "⚠ 세션 상한"
  [ "$o" -gt 0 ] && echo "⚠ 고아 claude $o 개: $(b3os_orphan_claude_pids | tr '\n' ' ')"
  [ "$b" -gt 0 ] && echo "⚠ 멤버 bun 초과분 $b 개"
  # ★카운터가 고장난 것과 "누수 0" 은 다르다.★ 세션이 있는데 멤버 bun 을 하나도 못 셌으면
  #   MCP 기동 모양이 바뀐 것이다. 이때 초과분은 음수가 되는데, ⚠ 는 양수에서만 나므로
  #   그냥 두면 ★숫자는 비명을 지르는데 경고는 침묵한다★ — 사람이 보는 것은 ⚠ 줄이다.
  [ "$s" -gt 0 ] && [ "$a" -eq 0 ] && echo "⚠ 멤버 bun 을 하나도 못 셌다 — MCP 프로세스 모양이 바뀌었을 수 있다(이 카운터는 무효)"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then b3os_capacity_report; fi
