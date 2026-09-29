import type { Database } from "bun:sqlite";
import { spawn } from "node:child_process";
import type { AgentRecord } from "../types";
import { insertLogLine, pruneLogLines, recentLogLines } from "../db/queries";
import type { Broadcaster } from "./types";

const POLL_INTERVAL_MS = 1000;
const PRUNE_EVERY_TICKS = 60;
// tmux 서버가 응답을 멈추면 capture-pane 자식이 영원히 안 끝난다 —
// 타임아웃 없이 매 tick 새로 spawn 하면 프로세스가 초당 1개씩 쌓여 uid 프로세스 한도(2666)를 터뜨린다.
const CAPTURE_TIMEOUT_MS = 5000;

interface TailState {
  lastDigest: string;
  lastLines: string[];
  ticks: number;
}

async function capturePane(session: string): Promise<string[]> {
  return new Promise((resolve) => {
    const proc = spawn("tmux", ["capture-pane", "-p", "-t", session, "-S", "-200"]);
    let out = "";
    let settled = false;
    const finish = (lines: string[]) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(lines);
    };
    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      finish([]);
    }, CAPTURE_TIMEOUT_MS);
    proc.stdout.on("data", (chunk) => (out += chunk.toString()));
    proc.on("error", () => finish([]));
    proc.on("close", (code) => {
      if (code !== 0) return finish([]);
      const lines = out.split("\n");
      while (lines.length && lines[lines.length - 1]?.trim() === "") lines.pop();
      finish(lines);
    });
  });
}

function digest(lines: string[]): string {
  if (!lines.length) return "";
  return `${lines.length}:${lines[lines.length - 1]}`;
}

function diffNewLines(prev: string[], next: string[]): string[] {
  if (!prev.length) return next.slice(-50);
  const lastPrev = prev[prev.length - 1];
  const idx = next.lastIndexOf(lastPrev ?? "__NOPE__");
  if (idx < 0) return next.slice(-50);
  return next.slice(idx + 1);
}

export function startTmuxTail(
  db: Database,
  agents: AgentRecord[],
  broadcast: Broadcaster,
): () => void {
  const states = new Map<string, TailState>();
  const intervals: NodeJS.Timeout[] = [];

  for (const agent of agents) {
    if (agent.status_provider !== "claude_tmux" || !agent.tmux_session) continue;
    const session = agent.tmux_session;
    const initial = recentLogLines(db, agent.id, 200).map((l) => l.line);
    states.set(agent.id, { lastDigest: digest(initial), lastLines: initial, ticks: 0 });

    const tick = async () => {
      const state = states.get(agent.id);
      if (!state) return;
      const lines = await capturePane(session);
      const d = digest(lines);
      if (d === state.lastDigest) {
        state.ticks++;
        if (state.ticks % PRUNE_EVERY_TICKS === 0) pruneLogLines(db, agent.id);
        return;
      }
      const newLines = diffNewLines(state.lastLines, lines);
      const now = new Date().toISOString();
      for (const line of newLines) {
        if (!line) continue;
        insertLogLine(db, agent.id, line);
        broadcast({ type: "log_line", agent_id: agent.id, line, captured_at: now });
      }
      state.lastDigest = d;
      state.lastLines = lines;
      state.ticks++;
      if (state.ticks % PRUNE_EVERY_TICKS === 0) pruneLogLines(db, agent.id);
    };

    // 이전 tick 이 아직 안 끝났으면 건너뛴다 — 겹쳐 돌면 자식 프로세스가 누적된다.
    let inFlight = false;
    intervals.push(
      setInterval(() => {
        if (inFlight) return;
        inFlight = true;
        void tick().finally(() => {
          inFlight = false;
        });
      }, POLL_INTERVAL_MS),
    );
  }

  return () => intervals.forEach((i) => clearInterval(i));
}
