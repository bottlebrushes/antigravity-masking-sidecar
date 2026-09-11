#!/usr/bin/env bun
/**
 * Cross-platform models.db routing helper for the Antigravity Masking Sidecar.
 *
 * Points every `google-antigravity` model in omp's model cache at the local
 * sidecar and keeps a one-time backup so the change can be reverted.
 *
 * Uses Bun's built-in `bun:sqlite`, so no Python 3 is required — that matters
 * on Windows, where `python3` is not guaranteed to be on PATH.
 *
 * Usage:
 *   bun patch-models-db.ts                 # route models at the sidecar
 *   bun patch-models-db.ts --restore       # restore the pre-sidecar backup
 *   bun patch-models-db.ts --db <path>     # override the models.db location
 */

import { Database } from "bun:sqlite";
import { copyFileSync, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PROVIDER_ID = "google-antigravity";

function resolveDbPath(): string {
  const flag = process.argv.indexOf("--db");
  if (flag !== -1 && process.argv[flag + 1]) return process.argv[flag + 1];
  if (process.env.OMP_MODELS_DB) return process.env.OMP_MODELS_DB;
  return join(homedir(), ".omp", "agent", "models.db");
}

const args = process.argv.slice(2);
const restore = args.includes("--restore");
const sidecarUrl = process.env.ANTIGRAVITY_SIDECAR_URL ?? "http://127.0.0.1:45123";
const upstreamUrl = process.env.ANTIGRAVITY_UPSTREAM_ORIGIN ?? "https://daily-cloudcode-pa.googleapis.com";

const dbPath = resolveDbPath();
const backupPath = `${dbPath}.pre-sidecar.bak`;

/** Read the baseUrl currently recorded for the provider, or null. */
function readBaseUrl(path: string): string | null {
  if (!existsSync(path)) return null;
  const db = new Database(path, { readonly: true });
  try {
    const row = db
      .query<{ models: string }, [string]>("SELECT models FROM model_cache WHERE provider_id = ?")
      .get(PROVIDER_ID);
    if (!row) return null;
    const models = JSON.parse(row.models) as Array<Record<string, unknown>>;
    const first = models.find((model) => typeof model.baseUrl === "string");
    return (first?.baseUrl as string) ?? null;
  } finally {
    db.close();
  }
}

/**
 * Rewrite every model's baseUrl through SQL.
 *
 * Restore deliberately goes through the database rather than copying the
 * backup file over models.db: the cache runs in WAL mode, so a plain file copy
 * leaves the patched pages in models.db-wal, and SQLite replays them on the
 * next open — silently undoing the restore.
 */
function setBaseUrl(url: string): void {
  if (!existsSync(dbPath)) {
    console.log(`[patch-models-db] ${dbPath} not found; skipping (omp has no model cache yet)`);
    return;
  }

  const db = new Database(dbPath);
  try {
    const row = db
      .query<{ models: string }, [string]>("SELECT models FROM model_cache WHERE provider_id = ?")
      .get(PROVIDER_ID);

    if (!row) {
      console.log(`[patch-models-db] no '${PROVIDER_ID}' entry in model_cache; skipping`);
      return;
    }

    const models = JSON.parse(row.models) as Array<Record<string, unknown>>;
    let changed = 0;
    for (const model of models) {
      if (model.baseUrl !== url) {
        model.baseUrl = url;
        changed += 1;
      }
    }

    db.run("UPDATE model_cache SET models = ? WHERE provider_id = ?", [
      JSON.stringify(models),
      PROVIDER_ID,
    ]);
    console.log(
      `[patch-models-db] routed ${changed}/${models.length} '${PROVIDER_ID}' models to ${url}`,
    );
  } finally {
    db.close();
  }
}

if (restore) {
  const original = readBaseUrl(backupPath) ?? upstreamUrl;
  setBaseUrl(original);
  if (existsSync(backupPath)) rmSync(backupPath);
  console.log(`[patch-models-db] restored models to ${original}`);
  process.exit(0);
}

if (!existsSync(backupPath)) {
  if (existsSync(dbPath)) {
    copyFileSync(dbPath, backupPath);
    console.log(`[patch-models-db] backup written to ${backupPath}`);
  }
}

setBaseUrl(sidecarUrl);

