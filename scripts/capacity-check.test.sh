#!/usr/bin/env bash
# 용량 카운터 — ★무엇을 세고 무엇을 안 세는가.★
#
# 이 시험이 지키는 불변식 두 개가 서로 반대 방향이다:
#   ① ★우리 것이 아닌 bun 은 세지 않는다★ — 셸에서 `bun test` 를 돌려도 초과분이 아니다.
#      (이전 판은 머신의 bun 을 전부 세어, 시험을 돌릴 때마다 경고가 났다.)
#   ② ★우리 것의 누수는 그대로 잡는다★ — 멤버 세션이 bun 을 하나 더 달면 초과분으로 나온다.
#   ①만 지키면 아무것도 안 잡는 카운터가 되고, ②만 지키면 계속 우는 카운터가 된다.
#
# ps 표는 B3OS_PS_TABLE_FILE 로, tmux 는 PATH 스텁으로 갈음한다.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../src/server/runtimes/claude/capacity-check.sh"
[ -r "$LIB" ] || { echo "라이브러리 없음: $LIB"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✅ $1"; }
bad() { fail=$((fail+1)); echo "  ❌ $1"; echo "     $2"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
SESS="$ROOT/sessions"; PSF="$ROOT/ps"

cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
S="${STUB_SESSIONS:?}"
case "$1" in
  ls) if [ "${2:-}" = "-F" ]; then cut -d' ' -f1 "$S"; else cut -d' ' -f1 "$S" | sed 's/$/: 1 windows/'; fi ;;
  list-panes)
    t=""; while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { t="$2"; break; }; shift; done
    awk -v n="$t" '$1==n {print $2}' "$S" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"

# 세션 목록: "<세션이름> <pane_pid>" 한 줄씩
# ps 표: "pid ppid comm" 한 줄씩
# 라이브러리를 한 번만 읽는다. 카운터들은 호출 시점에 env 를 보므로 케이스마다 다시 읽을
# 필요가 없다 — 케이스마다 서브셸을 띄우면 느리기만 하다.
export TMUX_BIN="$BIN/tmux" STUB_SESSIONS="$SESS" B3OS_PS_TABLE_FILE="$PSF"
# shellcheck source=/dev/null
. "$LIB"

measure() {  # stdout: "<초과분> <실제> <기대>"
  # 세 값을 각각 부르면 pane 조회가 세 번 돈다. 한 번씩만 부르고 차이는 여기서 낸다.
  local a e
  a=$(b3os_bun_actual); e=$(b3os_bun_expected)
  echo "$((a - e)) $a $e"
}

base_sessions() { : > "$SESS"; for i in 1 2 3; do echo "claude-m$i 100$i" >> "$SESS"; done; }
base_ps() {
  : > "$PSF"
  for i in 1 2 3; do
    echo "100$i 1 /Users/x/.local/bin/claude" >> "$PSF"   # pane 프로세스
    echo "200$i 100$i bun"                     >> "$PSF"   # MCP bun (claude 자식)
    echo "300$i 200$i /private/tmp/bun"        >> "$PSF"   # 그 bun 의 자식
  done
}

echo "── 1. 정상: 세션 3 × bun 2 → 초과분 0 ──"
base_sessions; base_ps
read -r x a e <<<"$(measure)"
[ "$x" = "0" ] && [ "$a" = "6" ] && [ "$e" = "6" ] && ok "초과분 0 (실제 6 / 기대 6)" || bad "0 6 6 이어야 한다" "받은 값: $x $a $e"

echo "── 2. ★멤버가 자기 셸에서 띄운 bun → 여전히 0 (오탐 없음)★ ──"
# ★이게 실제로 났던 오탐이다.★ 멤버의 Bash 도구 셸은 그 멤버 pane 의 자식이라,
# "pane 의 자손" 으로 세면 거기서 돌린 `bun test` 가 그대로 잡힌다. 사이에 셸이 끼는지를 본다.
base_sessions; base_ps
echo "8001 1001 /bin/zsh" >> "$PSF"; echo "9001 8001 bun" >> "$PSF"   # pane 밑 셸이 띄운 bun
echo "8002 1002 /bin/zsh" >> "$PSF"; echo "9002 8002 bun" >> "$PSF"
read -r x a e <<<"$(measure)"
[ "$x" = "0" ] && ok "초과분 0 — 셸을 거친 bun 은 안 센다 (실제 $a / 기대 $e)" || bad "멤버 셸의 bun 을 세면 안 된다" "초과분=$x (실제 $a / 기대 $e)"

echo "── 2b. 머신 어딘가의 무관한 bun → 여전히 0 ──"
base_sessions; base_ps
echo "8100 1 /bin/zsh" >> "$PSF"; echo "9100 8100 bun" >> "$PSF"
read -r x a e <<<"$(measure)"
[ "$x" = "0" ] && ok "초과분 0" || bad "무관한 bun 을 세면 안 된다" "초과분=$x (실제 $a / 기대 $e)"

echo "── 3. 서버 자신의 bun 2개(ppid 1) → 여전히 0 ──"
base_sessions; base_ps
echo "9100 1 bun" >> "$PSF"; echo "9101 9100 /private/tmp/bun" >> "$PSF"
read -r x a e <<<"$(measure)"
[ "$x" = "0" ] && ok "초과분 0 — 서버 bun 도 안 센다" || bad "서버 bun 을 세면 안 된다" "초과분=$x (실제 $a / 기대 $e)"

echo "── 4. ★멤버 세션이 bun 을 하나 더 달면 → 초과분 1 (누수는 잡힌다)★ ──"
base_sessions; base_ps
echo "2999 1001 bun" >> "$PSF"     # claude-m1 pane 밑에 붙은 여분 bun
read -r x a e <<<"$(measure)"
[ "$x" = "1" ] && ok "초과분 1 (실제 $a / 기대 $e)" || bad "누수를 잡아야 한다" "초과분=$x (실제 $a / 기대 $e)"

echo "── 5. MCP bun 밑에 붙은 여분도 잡는다 (2단까지 센다) ──"
base_sessions; base_ps
echo "3999 2001 bun" >> "$PSF"     # MCP bun 밑에 붙은 여분 bun
read -r x a e <<<"$(measure)"
[ "$x" = "1" ] && ok "초과분 1 — 2단도 센다" || bad "2단을 세야 한다" "초과분=$x (실제 $a / 기대 $e)"

echo "── 6. 세션이 하나도 없으면 0 (음수·오류 없음) ──"
: > "$SESS"; base_ps
read -r x a e <<<"$(measure)"
[ "$x" = "0" ] && [ "$a" = "0" ] && ok "초과분 0 · 실제 0" || bad "세션 0 이면 0 이어야 한다" "받은 값: $x $a $e"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
