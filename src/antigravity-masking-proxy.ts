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

const REPLACEMENTS: [RegExp, string][] = [
  // XML tag masking: normalize omp-specific tags to neutral equivalents
  [/<(\/?)system[-_]conventions>/gi, "<$1conventions>"],
  [/<(\/?)system[-_]directive>/gi, "<$1instructions>"],
  [/<(\/?)critical>/gi, "<$1important>"],

  // Textual identifiers: mask harness references
  [/Oh My Pi coding harness/gi, "AI coding assistant"],
  [/Oh My Pi/gi, "coding assistant"],
  [/omp Live/gi, "coding assistant live"],
];

function sanitizeText(raw: string): string {
  let text = raw;
  for (const [pattern, replacement] of REPLACEMENTS) {
    text = text.replace(pattern, replacement);
  }
  return text;
}

function sanitizePayload(jsonText: string): string {
  try {
    const parsed = JSON.parse(jsonText);

    // Sanitize any prompt texts
    const sanitizeRecursive = (val: any): any => {
      if (typeof val === "string") {
        return sanitizeText(val);
      }
      if (Array.isArray(val)) {
        return val.map(sanitizeRecursive);
      }
      if (val && typeof val === "object") {
        const out: Record<string, any> = {};
        for (const [k, v] of Object.entries(val)) {
          // Remove omp-injected flags that fingerprint third-party callers
          if (k === "used_claude_conservative" || k === "used_claude") {
            continue;
          }
          out[k] = sanitizeRecursive(v);
        }
        return out;
      }
      return val;
    };

    const cleaned = sanitizeRecursive(parsed);
    return JSON.stringify(cleaned);
  } catch {
    // If JSON parsing fails, apply regex-based sanitization directly to raw text
    return sanitizeText(jsonText);
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
        uptime: process.uptime()
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }

    const targetUrl = `${UPSTREAM_ORIGIN}${url.pathname}${url.search}`;

    // Build headers for upstream request (exclude hop-by-hop & incoming Host)
    const headers = new Headers();
    for (const [k, v] of req.headers.entries()) {
      const lower = k.toLowerCase();
      if (lower !== "host" && lower !== "connection") {
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
        requestBody = sanitizePayload(rawText);
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
