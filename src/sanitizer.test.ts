import { describe, expect, test } from "bun:test";
import { CANONICAL_CONVENTIONS, sanitizePayload, sanitizeText } from "./sanitizer";

describe("conventions canonicalization", () => {
  test("replaces arbitrary future language inside the complete block", () => {
    const input = `before
<system-conventions>
RFC 9999: MUST, SHOULD, MAY.
Future OMP wording that the sidecar has never seen.
</system-conventions>
after`;
    expect(sanitizeText(input)).toBe(`before\n${CANONICAL_CONVENTIONS}\nafter`);
  });

  test("accepts underscore tags and attributes", () => {
    const input = '<system_conventions version="19">anything</system_conventions>';
    expect(sanitizeText(input)).toBe(CANONICAL_CONVENTIONS);
  });

  test("does not rewrite an ordinary RFC discussion", () => {
    const input = "Compare RFC 2119 with RFC 8174 in this document.";
    expect(sanitizeText(input)).toBe(input);
  });

  test("does not rewrite bare omp identifiers", () => {
    const input = "Run omp --version and inspect /opt/omp/config.";
    expect(sanitizeText(input)).toBe(input);
  });
});

describe("payload sanitization", () => {
  test("removes only the established metadata and canonicalizes nested prompts", () => {
    const input = JSON.stringify({
      requestType: "agent",
      messages: [{ role: "system", text: "<system-conventions>new text</system-conventions>" }],
      metadata: { used_claude: true, keep: "yes" },
    });
    const result = sanitizePayload(input);
    expect(JSON.parse(result.body)).toEqual({
      messages: [{ role: "system", text: CANONICAL_CONVENTIONS }],
      metadata: { keep: "yes" },
    });
    expect(result.stats.conventionsBlocks).toBe(1);
    expect(result.stats.removedFields).toBe(2);
  });
});
