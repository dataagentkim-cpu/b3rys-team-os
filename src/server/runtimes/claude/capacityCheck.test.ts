/**
 * `scripts/capacity-check.test.sh` 를 실제로 돌리는 수트에 묶는다.
 * `.test.sh` 는 CI 도 `bun test` 도 수집하지 않으므로, 묶지 않으면 손으로 부를 때만 도는 장식이 된다.
 */
import { describe, expect, test } from "bun:test";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..", "..", "..", "..");
const SCRIPT = join(REPO, "scripts", "capacity-check.test.sh");

describe("용량 카운터", () => {
  test("셸 시험을 수트 안에서 돌린다", async () => {
    const p = Bun.spawn(["bash", SCRIPT], { cwd: REPO, stdout: "pipe", stderr: "pipe" });
    const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    const code = await p.exited;
    expect(code, `셸 시험 실패:\n${out}\n${err}`).toBe(0);
    // 종료코드만 보면 파일이 잘려도 통과한다 — 두 방향의 불변식이 실제로 돌았는지 본문으로 본다.
    expect(out, "오탐 방지 항목이 안 돌았다").toContain("오탐 없음");
    expect(out, "누수 검출 항목이 안 돌았다").toContain("누수는 잡힌다");
    // 이 시험은 프로세스를 여럿 띄운다. 기계가 바쁠 때는 프로세스 생성만으로 분 단위가
    // 되므로 여유를 둔다 — 60초로 두면 부하에 따라 통과·실패가 갈린다.
  }, 180_000);
});
