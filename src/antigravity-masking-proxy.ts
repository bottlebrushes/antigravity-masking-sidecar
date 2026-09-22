#!/usr/bin/env bun
/**
 * Antigravity Masking Sidecar Proxy
 *
 * Intercepts calls from omp to Google Antigravity (Cloud Code Assist API),
 * transparently masking harness identifiers, XML conventions tags, and
 * provider-specific telemetry labels before forwarding to Google.
 */

const PORT = parseInt(process.env.ANTIGRAVITY_SIDECAR_PORT || "45123", 10);
const HOST = process.env.ANTIGRAVITY_SIDECAR_HOST || "127.0.0.1";
const UPSTREAM_ORIGIN = process.env.ANTIGRAVITY_UPSTREAM_ORIGIN || "https://daily-cloudcode-pa.googleapis.com";

import { emptyStats, sanitizePayload, type SanitizeStats } from "./sanitizer";

const totals: SanitizeStats = emptyStats();

function recordStats(stats: SanitizeStats): void {
  for (const key of Object.keys(totals) as Array<keyof SanitizeStats>) {
    totals[key] += stats[key];
  }
}

const server = Bun.serve({
  port: PORT,
  hostname: HOST,
  async fetch(req) {
    const url = new URL(req.url);

    // Health check endpoint for systemd / wrapper probes
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({
        status: "ok",
        service: "omp-antigravity-sidecar",
        upstream: UPSTREAM_ORIGIN,
        port: PORT,
        uptime: process.uptime(),
        transforms: totals,
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }

    const targetUrl = `${UPSTREAM_ORIGIN}${url.pathname}${url.search}`;

    // Build headers for upstream request (exclude hop-by-hop & incoming Host)
    const headers = new Headers();
    for (const [k, v] of req.headers.entries()) {
      const lower = k.toLowerCase();
      if (lower !== "host" && lower !== "connection" && lower !== "content-length") {
        headers.set(k, v);
      }
    }

    // Standardize client metadata to match official Antigravity IDE
    const existingUa = headers.get("User-Agent") || "";
    if (!existingUa || existingUa.includes("omp") || existingUa.includes("electron-builder")) {
      headers.set("User-Agent", "antigravity/hub/2.8.0 (aidev_client; os_type=linux; arch=x64; cl=963137146)");
    }
    if (!headers.has("Client-Metadata")) {
      headers.set("Client-Metadata", "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI");
    }

    let requestBody: string | ArrayBuffer | undefined = undefined;

    if (req.method === "POST" || req.method === "PUT" || req.method === "PATCH") {
      const contentType = req.headers.get("Content-Type") || "";
      if (contentType.includes("application/json")) {
        const rawText = await req.text();
        const sanitized = sanitizePayload(rawText);
        requestBody = sanitized.body;
        recordStats(sanitized.stats);
      } else {
        requestBody = await req.arrayBuffer();
      }
    }

    try {
      const upstreamResp = await fetch(targetUrl, {
        method: req.method,
        headers,
        body: requestBody
      });

      const respHeaders = new Headers(upstreamResp.headers);
      respHeaders.delete("content-encoding");

      return new Response(upstreamResp.body, {
        status: upstreamResp.status,
        statusText: upstreamResp.statusText,
        headers: respHeaders
      });
    } catch (err: any) {
      console.error(`[Sidecar] Upstream request failed (${targetUrl}):`, err);
      return new Response(
        JSON.stringify({
          error: {
            code: 502,
            message: `Antigravity sidecar forwarding error: ${err.message}`,
            status: "BAD_GATEWAY"
          }
        }),
        {
          status: 502,
          headers: { "Content-Type": "application/json" }
        }
      );
    }
  }
});

console.log(`[Antigravity Masking Sidecar] Running on http://${HOST}:${PORT} (Upstream: ${UPSTREAM_ORIGIN})`);

// Handle shutdown cleanly
process.on("SIGINT", () => {
  console.log("[Antigravity Masking Sidecar] Shutting down...");
  server.stop();
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("[Antigravity Masking Sidecar] Shutting down...");
  server.stop();
  process.exit(0);
});
