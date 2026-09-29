/**
 * `scripts/session-cap-gate.test.sh` 를 ★실제로 돌리는 수트에 묶는다.★
 *
 * `.test.sh` 는 아무것도 자동으로 돌리지 않는다 — CI 는 타입체크만 하고 `bun test` 는
 * `.test.sh` 를 수집하지 않는다. 묶지 않으면 회귀 시험이 손으로 부를 때만 도는 장식이 된다.
 * `sendToolsHonesty.test.ts` 와 같은 형태다.
 */
import { describe, expect, test } from "bun:test";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..", "..", "..", "..");
const SCRIPT = join(REPO, "scripts", "session-cap-gate.test.sh");

describe("세션 수 상한 게이트", () => {
  test("셸 시험을 수트 안에서 돌린다", async () => {
    const p = Bun.spawn(["bash", SCRIPT], { cwd: REPO, stdout: "pipe", stderr: "pipe" });
    const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    const code = await p.exited;
    expect(code, `셸 시험 실패:\n${out}\n${err}`).toBe(0);
    // 종료코드만 보면 파일이 잘려도 통과한다 — 경계 항목이 실제로 돌았는지 본문으로 확인한다.
    expect(out, "재시작 복구 경로가 안 돌았다").toContain("재시작 신호");
    expect(out, "kill 뒤에도 상한 이상인 경계가 안 돌았다").toContain("C2.");
  }, 60_000);
});
