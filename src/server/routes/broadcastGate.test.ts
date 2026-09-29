/**
 * ★팀원 broadcast 게이트★
 *
 * ═══ 왜 생겼나 — 실측 ═══
 * `--to broadcast` 는 누구나 아무 때나 칠 수 있었고 검사도 기록도 없었다.
 * 70분간 팀원 broadcast ★47건 → wake 517회★. 1건이 11명을 깨우고, 깨어난 사람이 또 쏜다.
 * ★팀장님 @all 은 7명인데 팀원 혼잣말이 11명을 깨웠다★ — 구조가 뒤집혀 있었다.
 * 룰에는 "결과는 TERMINAL, 확인 답장 금지" 가 이미 있었지만 지켜지지 않았다(47건 중 5건이 내 것).
 *
 * ★그래서 룰이 아니라 게이트로 막는다.★ 판단을 9명에게 맡기지 않고 coordinator 한 곳으로 모은다.
 *
 * 계약 두 개:
 *  ① 팀원 전체공지 = 정식·활성 자격 + `all_hands` 사유가 있어야 한다
 *  ② broadcast 에 대한 답은 broadcast 로 못 한다 (coordinator 라도) — 연쇄의 직접 고리
 */
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Database } from "bun:sqlite";
import { ALL_HANDS_CAP_PER_HOUR_DEFAULT, allHandsHourlyCap, createInboxRoutes, retryAfterSec } from "./inbox";
import { migrate } from "../db/migrate";
import type { AgentRecord } from "../types";

const ROSTER: AgentRecord[] = [
  { id: "bill", display_name: "Bill", role: "infra", capabilities: ["coordinator"] },
  { id: "steve", display_name: "Steve", role: "dev", capabilities: ["full_context"] },
  { id: "lui", display_name: "Lui", role: "dev" },
] as never;

function app(roster: AgentRecord[] = ROSTER, routeRoster: AgentRecord[] = roster) {
  const db = new Database(":memory:");
  migrate(db);
  for (const a of roster) {
    db.prepare(
      `INSERT OR IGNORE INTO agent (id, display_name, role, runtime, status_provider, workspace_path, persona_file)
       VALUES (?,?,?,'claude_channel','claude_tmux','/tmp','p.md')`,
    ).run(a.id, a.display_name, a.role);
  }
  db.prepare(
    `INSERT OR IGNORE INTO thread (id, title, kind, participants_json, opened_by)
     VALUES ('thread-broadcast-gate','gate','broadcast','["bill","steve","lui"]','bill')`,
  ).run();
  const h = createInboxRoutes({
    db,
    broadcast: () => {},
    registeredAgentIds: () => new Set(roster.map((a) => a.id)),
    agents: () => routeRoster,
  } as never);
  return { h, db };
}

const send = (h: ReturnType<typeof createInboxRoutes>, body: Record<string, unknown>) =>
  h.request("/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      from_agent_id: "steve", to_agent_id: "broadcast", type: "broadcast",
      body: "…", source: "agent", thread_id: "thread-broadcast-gate", ...body,
    }),
  });

// ★coordinator 요구는 뺐다 (2026-08-01)★ — 넣었더니 방이 통째로 조용해졌다.
// 에 아무도 방에 답하지 못했다. 과녁은 ★연쇄★ 였지 발언 자체가 아니었다.
//   그래서 그 계약을 검사하던 시험도 같이 지운다. 남는 계약은 아래 하나뿐이다.

describe("★broadcast 에 대한 답은 broadcast 로 못 한다★ — 연쇄의 직접 고리", () => {
  it("부모가 broadcast 면 coordinator 라도 거부한다 (연쇄는 발신자를 안 가린다)", async () => {
    const { h, db } = app();
    db.prepare(
      `INSERT INTO message (id, thread_id, from_agent_id, to_agent_id, type, body, source, created_at)
       VALUES ('PARENT-BCAST','thread-broadcast-gate','lui','broadcast','broadcast','공지','agent',datetime('now'))`,
    ).run();
    const res = await send(h, { from_agent_id: "bill", all_hands: "이유 있음", in_reply_to: "PARENT-BCAST" });
    expect(res.status, "★broadcast 답장이 broadcast 로 나갔다 — 오늘 47건 중 18건이 이 형태★").toBe(403);
    expect((await res.json()).error).toBe("broadcast_reply_to_broadcast");
  });

  it("부모가 1:1 이면 (coordinator+이유 조건은 그대로) 통과한다", async () => {
    const { h, db } = app();
    db.prepare(
      `INSERT INTO message (id, thread_id, from_agent_id, to_agent_id, type, body, source, created_at)
       VALUES ('PARENT-DM','thread-broadcast-gate','lui','bill','dm','질문','agent',datetime('now'))`,
    ).run();
    const res = await send(h, { from_agent_id: "bill", all_hands: "전원 공지", in_reply_to: "PARENT-DM" });
    expect(res.status, "★1:1 답장을 broadcast 로 올리는 것은 이 게이트가 막지 않는다★").not.toBe(403);
  });
});

describe("★팀장님 경로는 이 게이트를 타지 않는다★", () => {
  it("source=user 의 broadcast(@all)는 라우터가 판정하므로 여기서 막지 않는다", async () => {
    const { h } = app();
    const res = await send(h, { from_agent_id: "user", source: "user" });
    expect(res.status, "★팀장님 @all 을 막으면 안 된다★").not.toBe(403);
  });
});

describe("★all_hands 전체공지는 사유·발신자격·감사를 강제한다★", () => {
  it("정식·활성 팀원은 보내고 사유·수신자 수를 DB 감사에 남긴다", async () => {
    const { h, db } = app();
    const res = await send(h, { from_agent_id: "steve", all_hands: "운영 점검" });
    expect(res.status).not.toBe(403);
    expect(res.status).not.toBe(503);
    const row = db.prepare(
      `SELECT detail_json FROM audit_event WHERE actor='steve' AND action='agent_broadcast_all_hands' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(row.detail_json)).toMatchObject({
      reason: "운영 점검",
      recipient_count: 2,
      eligible_recipient_count: 2,
      zero_reason: null,
    });
  });

  it("비정식 팀원은 전체공지를 보내지 못한다", async () => {
    const roster = [
      { ...ROSTER[0]! },
      { ...ROSTER[1]!, team_official_member: false, lead_eligible: false },
    ] as AgentRecord[];
    const { h } = app(roster);
    const res = await send(h, { from_agent_id: "steve", all_hands: "운영 점검" });
    expect(res.status).toBe(403);
    expect((await res.json()).error).toBe("all_hands_sender_ineligible");
  });

  it("source를 user로 속여도 all_hands 판정·감사를 우회하지 못한다", async () => {
    const roster = [
      { ...ROSTER[0]! },
      { ...ROSTER[1]!, team_official_member: false, lead_eligible: false },
    ] as AgentRecord[];
    const { h, db } = app(roster);
    const res = await send(h, { from_agent_id: "steve", source: "user", all_hands: "우회 시도" });
    expect(res.status).toBe(403);
    expect((await res.json()).error).toBe("all_hands_sender_ineligible");
    const audit = db.prepare(
      `SELECT detail_json FROM audit_event WHERE action='agent_all_hands_blocked' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(audit.detail_json)).toMatchObject({
      reason: "우회 시도",
      identity_basis: "claimed_from_agent_id",
    });
  });

  it("인증 신원이 없는 현재 API에서는 정식 팀원 from_agent_id 사칭을 구분하지 못함을 고정한다", async () => {
    const { h, db } = app();
    const res = await send(h, { from_agent_id: "steve", source: "user", all_hands: "사칭 한계 기록" });
    expect(res.status).not.toBe(403);
    const audit = db.prepare(
      `SELECT detail_json FROM audit_event WHERE action='agent_broadcast_all_hands' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(audit.detail_json)).toMatchObject({
      reason: "사칭 한계 기록",
      identity_basis: "claimed_from_agent_id",
    });
  });

  it("꺼진 팀원은 전체공지를 보내지 못한다", async () => {
    const roster = [
      { ...ROSTER[0]! },
      { ...ROSTER[1]!, enabled: false },
    ] as AgentRecord[];
    const { h } = app(roster);
    const res = await send(h, { from_agent_id: "steve", all_hands: "운영 점검" });
    expect(res.status).toBe(403);
    expect((await res.json()).error).toBe("all_hands_sender_ineligible");
  });

  it("명부에서 발신자를 확인하지 못하면 성공시키지 않는다", async () => {
    const { h, db } = app(ROSTER, []);
    const res = await send(h, { from_agent_id: "steve", all_hands: "운영 점검" });
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("all_hands_roster_unavailable");
    const audit = db.prepare(
      `SELECT detail_json FROM audit_event WHERE action='agent_all_hands_blocked' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(audit.detail_json).error).toBe("sender_missing_from_registry");
  });

  it("발신자만 있는 명부의 수신행 0은 sender_only로 기록한다", async () => {
    const roster = [{ ...ROSTER[0]! }] as AgentRecord[];
    const { h, db } = app(roster);
    const res = await send(h, { from_agent_id: "bill", all_hands: "개인 설치 확인" });
    expect(res.status).not.toBe(403);
    expect(res.status).not.toBe(503);
    const row = db.prepare(
      `SELECT detail_json FROM audit_event WHERE action='agent_broadcast_all_hands' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(row.detail_json)).toMatchObject({ recipient_count: 0, zero_reason: "sender_only" });
  });

  it("명부 수신자가 DB에 없어 수신행 0이면 registry_db_out_of_sync로 기록한다", async () => {
    const dbRoster = [{ ...ROSTER[1]! }] as AgentRecord[];
    const routeRoster = [{ ...ROSTER[1]! }, { ...ROSTER[0]! }] as AgentRecord[];
    const { h, db } = app(dbRoster, routeRoster);
    const res = await send(h, { from_agent_id: "steve", all_hands: "명부 동기화 확인" });
    expect(res.status).not.toBe(403);
    expect(res.status).not.toBe(503);
    const row = db.prepare(
      `SELECT detail_json FROM audit_event WHERE action='agent_broadcast_all_hands' ORDER BY id DESC LIMIT 1`,
    ).get() as { detail_json: string };
    expect(JSON.parse(row.detail_json)).toMatchObject({
      recipient_count: 0,
      eligible_recipient_count: 1,
      zero_reason: "registry_db_out_of_sync",
    });
  });
});

/**
 * ★전원공지 시간당 상한★
 *
 * 자격 검사는 "보낼 수 있는가"만 본다. "얼마나 자주"는 보지 않는다.
 * 전원공지 1건은 명부 전원의 턴을 소모하므로, 상한이 없으면 1인이 짧은 사이에
 * 반복해 전원의 턴을 몇 배로 태울 수 있다. 실측: 전원공지 2건이 90초 안에 나가
 * 각 6명을 깨웠다(멤버 턴 12개).
 *
 * 세는 것은 새 상태가 아니라 성공 기록(`agent_broadcast_all_hands`)이다 —
 * 재시작·배포에도 창이 유지되고 마이그레이션이 필요 없다.
 */
describe("★전원공지 시간당 상한★", () => {
  const ENV_KEY = "BUS_ALL_HANDS_MAX_PER_HOUR";
  let saved: string | undefined;

  beforeEach(() => { saved = process.env[ENV_KEY]; });
  afterEach(() => {
    if (saved === undefined) delete process.env[ENV_KEY];
    else process.env[ENV_KEY] = saved;
  });

  // 본문을 매번 다르게 한다 — acceptInbound 의 60초 dedupe 가 같은 본문을 삼켜
  // 상한이 아니라 dedupe 를 시험하게 되는 것을 막는다.
  const blast = (h: ReturnType<typeof createInboxRoutes>, i: number) =>
    send(h, { from_agent_id: "steve", all_hands: `공지 ${i}`, body: `전원 공지 본문 ${i}` });

  it("상한까지는 통과하고 그 다음 1건을 429 로 막는다", async () => {
    process.env[ENV_KEY] = "2";
    const { h } = app();
    expect((await blast(h, 1)).status).not.toBe(429);
    expect((await blast(h, 2)).status).not.toBe(429);

    const blocked = await blast(h, 3);
    expect(blocked.status).toBe(429);
    const body = (await blocked.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ error: "all_hands_rate_limited", cap_per_hour: 2, sent_last_hour: 2 });
    // 언제 다시 되는지 알려줘야 한다 — 모르면 발신자가 계속 두드린다.
    expect(body.retry_after_sec as number).toBeGreaterThan(0);
    expect(body.retry_after_sec as number).toBeLessThanOrEqual(3600);
  });

  it("막힌 시도는 한도를 소모하지 않는다 — 성공 기록이 늘지 않는다", async () => {
    process.env[ENV_KEY] = "1";
    const { h, db } = app();
    expect((await blast(h, 1)).status).not.toBe(429);
    expect((await blast(h, 2)).status).toBe(429);
    expect((await blast(h, 3)).status).toBe(429);

    const sent = db.prepare(
      `SELECT COUNT(*) AS n FROM audit_event WHERE action='agent_broadcast_all_hands'`,
    ).get() as { n: number };
    expect(sent.n).toBe(1);
  });

  it("차단을 사유와 함께 기록한다 — 사후에 누가 몇 건 쳤는지 판정할 수 있어야 한다", async () => {
    process.env[ENV_KEY] = "1";
    const { h, db } = app();
    await blast(h, 1);
    await blast(h, 2);
    const row = db.prepare(
      `SELECT actor, detail_json FROM audit_event WHERE action='agent_all_hands_blocked' ORDER BY id DESC LIMIT 1`,
    ).get() as { actor: string; detail_json: string };
    expect(row.actor).toBe("steve");
    expect(JSON.parse(row.detail_json)).toMatchObject({
      error: "rate_limited",
      cap_per_hour: 1,
      sent_last_hour: 1,
      reason: "공지 2",
    });
  });

  it("상한은 발신자별이다 — 한 사람이 채워도 다른 사람은 막히지 않는다", async () => {
    process.env[ENV_KEY] = "1";
    const { h } = app();
    expect((await blast(h, 1)).status).not.toBe(429);
    expect((await blast(h, 2)).status).toBe(429);
    const other = await send(h, { from_agent_id: "bill", all_hands: "다른 발신자", body: "다른 발신자 본문" });
    expect(other.status).not.toBe(429);
  });

  it("60분보다 오래된 기록은 세지 않는다 — 고정창이 아니라 흐르는 창이다", async () => {
    process.env[ENV_KEY] = "1";
    const { h, db } = app();
    db.prepare(
      `INSERT INTO audit_event (actor, action, target, detail_json, at)
       VALUES ('steve','agent_broadcast_all_hands',NULL,'{}',datetime('now','-61 minutes'))`,
    ).run();
    expect((await blast(h, 1)).status).not.toBe(429);
  });

  it("off 면 상한을 걸지 않는다", async () => {
    process.env[ENV_KEY] = "off";
    const { h } = app();
    for (let i = 1; i <= 4; i += 1) expect((await blast(h, i)).status).not.toBe(429);
  });

  it("0 이면 전원공지를 전면 차단한다 — off 와 다른 값이다", async () => {
    process.env[ENV_KEY] = "0";
    const { h } = app();
    expect((await blast(h, 1)).status).toBe(429);
  });
});

describe("allHandsHourlyCap — 설정값 해석", () => {
  it("없으면 기본 상한을 쓴다", () => {
    expect(allHandsHourlyCap(undefined)).toBe(ALL_HANDS_CAP_PER_HOUR_DEFAULT);
  });

  it("★오타는 '상한 없음' 으로 번지지 않는다★ — 숫자가 아니면 기본값으로 떨어진다", () => {
    for (const bad of ["", " ", "abc", "3건", "-1", "2.5"]) {
      expect(allHandsHourlyCap(bad)).toBe(ALL_HANDS_CAP_PER_HOUR_DEFAULT);
    }
  });

  it("off 만 상한을 끈다 — 끄는 것은 항상 명시적이다", () => {
    expect(allHandsHourlyCap("off")).toBeNull();
    expect(allHandsHourlyCap("OFF")).toBeNull();
  });

  it("정수는 그대로 상한이 된다", () => {
    expect(allHandsHourlyCap("0")).toBe(0);
    expect(allHandsHourlyCap("7")).toBe(7);
  });
});

describe("retryAfterSec — at 은 UTC 다", () => {
  it("★Z 를 붙여 해석한다★ — 안 붙이면 KST 로 읽혀 9시간 틀린다", () => {
    const now = Date.parse("2026-09-29T03:00:00Z");
    // 30분 전에 창이 시작됐으면 30분(1800초) 남는다.
    expect(retryAfterSec("2026-09-29 02:30:00", now)).toBe(1800);
  });

  it("창이 이미 지났으면 0 이다 (음수로 내려가지 않는다)", () => {
    const now = Date.parse("2026-09-29T03:00:00Z");
    expect(retryAfterSec("2026-09-29 01:00:00", now)).toBe(0);
  });

  it("기록이 없으면 0 이다", () => {
    expect(retryAfterSec(null)).toBe(0);
  });
});
