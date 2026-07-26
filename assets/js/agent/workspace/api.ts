// Data layer for the workspace sidebar: the file tree's directory listings
// and the git panel's status/diff/mutations, over longpi's plain-JSON tool
// endpoints (see LongpiWeb.WorkspaceController).

import { buildCSRFHeaders } from "../../ash_rpc";
import type { DirListing } from "./tree";

export type GitFile = { path: string; status: string; staged: boolean; unstaged: boolean };

export type GitStatus = {
  repo: boolean;
  root: string | null;
  branch: string | null;
  files: GitFile[];
};

export type GitCommit = { hash: string; author: string; date: string; subject: string };

export type FileAt = { content: string; binary: boolean; truncated: boolean; missing: boolean };

export type GitDiff = { diff: string; binary: boolean; truncated: boolean };

async function get<T>(url: string): Promise<T | null> {
  try {
    const res = await fetch(url, { headers: buildCSRFHeaders() });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

async function post(url: string, body: Record<string, unknown>): Promise<string | null> {
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { ...buildCSRFHeaders(), "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.ok) return null;
    const payload = (await res.json().catch(() => null)) as { error?: string } | null;
    return payload?.error ?? `request failed (${res.status})`;
  } catch (error) {
    return String(error);
  }
}

const q = (params: Record<string, string>) => new URLSearchParams(params).toString();

export const listDir = (path: string) =>
  get<DirListing>(`/rpc/workspace/dir?${q({ path })}`);

export const gitStatus = (cwd: string) => get<GitStatus>(`/rpc/git/status?${q({ cwd })}`);

export const gitDiff = (cwd: string, file: string, staged: boolean) =>
  get<GitDiff>(`/rpc/git/diff?${q({ cwd, file, staged: staged ? "1" : "0" })}`);

export const gitFileAt = (cwd: string, rev: string, file: string) =>
  get<FileAt>(`/rpc/git/file?${q({ cwd, rev, file })}`);

export const gitLog = (cwd: string) =>
  get<{ commits: GitCommit[] }>(`/rpc/git/log?${q({ cwd })}`);

export const gitShow = (cwd: string, hash: string) =>
  get<{ text: string; truncated: boolean }>(`/rpc/git/show?${q({ cwd, hash })}`);

export const gitStage = (cwd: string, file: string) => post("/rpc/git/stage", { cwd, file });
export const gitUnstage = (cwd: string, file: string) => post("/rpc/git/unstage", { cwd, file });
export const gitDiscard = (cwd: string, file: string) => post("/rpc/git/discard", { cwd, file });

export const gitCommit = (cwd: string, message: string, amend: boolean) =>
  post("/rpc/git/commit", { cwd, message, amend });
