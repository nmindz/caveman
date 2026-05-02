/**
 * Caveman plugin for OpenCode CLI.
 *
 * Ports the Claude Code mode-tracker hook to OpenCode's plugin API.
 *
 * Responsibilities:
 *   1. Slash-command activation: `/caveman`, `/caveman lite|full|ultra|wenyan...`,
 *      `/caveman-commit`, `/caveman-review`, `/caveman-compress`.
 *   2. Natural-language activation/deactivation: "talk like caveman",
 *      "stop caveman", "normal mode", etc.
 *   3. Symlink-safe write of the active mode to a flag file at
 *      `${OPENCODE_CONFIG_DIR or ~/.config/opencode}/.caveman-active`.
 *
 * Environment variables (parity with Claude Code hook):
 *   OPENCODE_CONFIG_DIR  Override config directory (default: ~/.config/opencode)
 *   CAVEMAN_DEFAULT_MODE Override default mode for bare `/caveman` (default: full)
 *
 * The persistent caveman ruleset itself ships in AGENTS.md (between markers
 * `<!-- BEGIN CAVEMAN -->` / `<!-- END CAVEMAN -->`), which OpenCode reloads
 * every session. Per-turn ruleset reinforcement (which the Claude Code hook
 * does via UserPromptSubmit `hookSpecificOutput`) is not possible in OpenCode,
 * so the AGENTS.md block must carry that weight.
 */

import type { Plugin } from "@opencode-ai/plugin";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const VALID_MODES = new Set([
  "off",
  "lite",
  "full",
  "ultra",
  "wenyan-lite",
  "wenyan",
  "wenyan-full",
  "wenyan-ultra",
  "commit",
  "review",
  "compress",
]);

// Modes that are one-shot independent skills, not persistent caveman style.
const INDEPENDENT_MODES = new Set(["commit", "review", "compress"]);

const ACTIVATE_RE_A =
  /\b(activate|enable|turn on|start|talk like)\b.*\bcaveman\b/i;
const ACTIVATE_RE_B = /\bcaveman\b.*\b(mode|activate|enable|turn on|start)\b/i;
const DEACTIVATE_RE =
  /\b(stop|disable|turn off|deactivate|exit|end)\b.*\bcaveman\b/i;
const NORMAL_MODE_RE = /\bnormal\s+mode\b/i;

function configDir(): string {
  return (
    process.env.OPENCODE_CONFIG_DIR ??
    path.join(os.homedir(), ".config", "opencode")
  );
}

function flagPath(): string {
  return path.join(configDir(), ".caveman-active");
}

function defaultMode(): string {
  const env = process.env.CAVEMAN_DEFAULT_MODE;
  if (env && VALID_MODES.has(env)) return env;

  // Fallback: ~/.config/caveman/config.json (XDG-aware), parity with caveman-config.js
  const xdg = process.env.XDG_CONFIG_HOME;
  const candidates = [
    xdg ? path.join(xdg, "caveman", "config.json") : null,
    path.join(os.homedir(), ".config", "caveman", "config.json"),
    process.env.APPDATA
      ? path.join(process.env.APPDATA, "caveman", "config.json")
      : null,
  ].filter((p): p is string => p !== null);

  for (const candidate of candidates) {
    try {
      const raw = fs.readFileSync(candidate, "utf8");
      const parsed = JSON.parse(raw) as { defaultMode?: unknown };
      if (
        typeof parsed.defaultMode === "string" &&
        VALID_MODES.has(parsed.defaultMode)
      ) {
        return parsed.defaultMode;
      }
    } catch {
      // Silent fall-through — never block on config read errors.
    }
  }
  return "full";
}

/**
 * Write `content` to `target` atomically, refusing to follow symlinks.
 * Protects against an attacker (or stale symlink) at the predictable flag
 * path being used to clobber another file the user owns.
 *
 * Silent-fails on every filesystem error — never throws. The flag is best-
 * effort metadata; a failed write must not break the user's session.
 */
function safeWriteFlag(target: string, content: string): void {
  try {
    const dir = path.dirname(target);

    // Ensure parent exists. mkdir is fine even if the dir is a symlink
    // pointing somewhere legitimate (the user's own config dir may be one).
    try {
      fs.mkdirSync(dir, { recursive: true });
    } catch {
      // ignore
    }

    // Refuse if the target itself is a symlink — never follow.
    try {
      const lst = fs.lstatSync(target);
      if (lst.isSymbolicLink()) return;
    } catch {
      // ENOENT is fine — we'll create it.
    }

    // Refuse if the parent directory is a symlink to somewhere unexpected.
    // We allow it if it resolves under the user's home.
    try {
      const parentLst = fs.lstatSync(dir);
      if (parentLst.isSymbolicLink()) {
        const resolved = fs.realpathSync(dir);
        if (!resolved.startsWith(os.homedir())) return;
      }
    } catch {
      // ignore
    }

    // Atomic temp + rename, with O_NOFOLLOW where supported.
    const tmp = `${target}.${process.pid}.${Date.now()}.tmp`;
    const flags =
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (fs.constants as any).O_WRONLY |
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (fs.constants as any).O_CREAT |
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (fs.constants as any).O_TRUNC |
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ((fs.constants as any).O_NOFOLLOW ?? 0);

    let fd: number | null = null;
    try {
      fd = fs.openSync(tmp, flags, 0o600);
      fs.writeSync(fd, content);
    } finally {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch {
          // ignore
        }
      }
    }

    fs.renameSync(tmp, target);
  } catch {
    // Silent fail — flag write is best-effort.
  }
}

function clearFlag(target: string): void {
  try {
    fs.unlinkSync(target);
  } catch {
    // ignore — file may not exist
  }
}

interface PromptDecision {
  kind: "set" | "clear" | "noop";
  mode?: string;
}

function decide(prompt: string): PromptDecision {
  const trimmed = prompt.trim();
  if (trimmed.length === 0) return { kind: "noop" };

  // --- Slash-command activation ---
  if (trimmed.startsWith("/")) {
    const parts = trimmed.split(/\s+/);
    const head = parts[0]?.toLowerCase();
    const arg = parts[1]?.toLowerCase();

    switch (head) {
      case "/caveman": {
        if (!arg) return { kind: "set", mode: defaultMode() };
        if (arg === "off" || arg === "stop" || arg === "disable") {
          return { kind: "clear" };
        }
        if (VALID_MODES.has(arg)) return { kind: "set", mode: arg };
        // Unknown level → fall back to default
        return { kind: "set", mode: defaultMode() };
      }
      case "/caveman-commit":
        return { kind: "set", mode: "commit" };
      case "/caveman-review":
        return { kind: "set", mode: "review" };
      case "/caveman-compress":
        return { kind: "set", mode: "compress" };
      default:
        // Other slash commands — leave caveman state untouched.
        return { kind: "noop" };
    }
  }

  // --- Natural-language deactivation (checked first; "stop caveman mode"
  //     contains "caveman ... mode" which would otherwise activate). ---
  if (DEACTIVATE_RE.test(trimmed) || NORMAL_MODE_RE.test(trimmed)) {
    return { kind: "clear" };
  }

  // --- Natural-language activation ---
  if (ACTIVATE_RE_A.test(trimmed) || ACTIVATE_RE_B.test(trimmed)) {
    return { kind: "set", mode: defaultMode() };
  }

  return { kind: "noop" };
}

interface MessagePart {
  type?: string;
  text?: string;
}

interface MessageInfo {
  role?: string;
  parts?: MessagePart[];
}

function extractPromptText(info: MessageInfo | undefined): string {
  if (!info?.parts || !Array.isArray(info.parts)) return "";
  const chunks: string[] = [];
  for (const part of info.parts) {
    if (part?.type === "text" && typeof part.text === "string") {
      chunks.push(part.text);
    }
  }
  return chunks.join("\n");
}

/**
 * Resolve session-start auto-activation mode.
 *
 * Returns a mode string when the user has *explicitly* opted in to a default
 * via `CAVEMAN_DEFAULT_MODE` or `~/.config/caveman/config.json` `defaultMode`.
 * Returns null when no explicit opt-in exists — in that case we leave the
 * flag file untouched so users who never asked for caveman never get it.
 */
function autoActivateMode(): string | null {
  const env = process.env.CAVEMAN_DEFAULT_MODE;
  if (env && VALID_MODES.has(env)) return env;

  const xdg = process.env.XDG_CONFIG_HOME;
  const candidates = [
    xdg ? path.join(xdg, "caveman", "config.json") : null,
    path.join(os.homedir(), ".config", "caveman", "config.json"),
    process.env.APPDATA
      ? path.join(process.env.APPDATA, "caveman", "config.json")
      : null,
  ].filter((p): p is string => p !== null);

  for (const candidate of candidates) {
    try {
      const raw = fs.readFileSync(candidate, "utf8");
      const parsed = JSON.parse(raw) as { defaultMode?: unknown };
      if (
        typeof parsed.defaultMode === "string" &&
        VALID_MODES.has(parsed.defaultMode)
      ) {
        return parsed.defaultMode;
      }
    } catch {
      // ignore
    }
  }
  return null;
}

export const CavemanPlugin: Plugin = async () => {
  const target = flagPath();

  // Session-start auto-activation: if the user has explicitly opted in via
  // CAVEMAN_DEFAULT_MODE env var or persistent config.json defaultMode, write
  // the flag now so the very first prompt of the session is already in
  // caveman mode — no need to type `/caveman` first. Mirrors the Claude Code
  // SessionStart hook behavior. If neither is set, we do nothing and the
  // flag file is left in whatever state the previous session left it.
  const auto = autoActivateMode();
  if (auto !== null) {
    safeWriteFlag(target, auto);
  }

  return {
    "message.updated": async (props: unknown) => {
      const p = props as { properties?: { info?: MessageInfo } } | undefined;
      const info = p?.properties?.info;
      if (info?.role !== "user") return;

      const prompt = extractPromptText(info);
      if (prompt.length === 0) return;

      const decision = decide(prompt);
      if (decision.kind === "set" && decision.mode) {
        safeWriteFlag(target, decision.mode);
      } else if (decision.kind === "clear") {
        clearFlag(target);
      }
    },
  };
};
