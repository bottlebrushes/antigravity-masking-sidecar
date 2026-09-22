export const CANONICAL_CONVENTIONS = `<guidelines>
Requirement terminology: MUST means mandatory, SHOULD means recommended, and MAY means optional.
</guidelines>`;

export type SanitizeStats = {
  conventionsBlocks: number;
  standaloneRfcClauses: number;
  structuralTags: number;
  harnessIdentifiers: number;
  removedFields: number;
};

export function emptyStats(): SanitizeStats {
  return {
    conventionsBlocks: 0,
    standaloneRfcClauses: 0,
    structuralTags: 0,
    harnessIdentifiers: 0,
    removedFields: 0,
  };
}

function replaceCounted(
  text: string,
  pattern: RegExp,
  replacement: string,
  stats: SanitizeStats,
  key: keyof Omit<SanitizeStats, "removedFields">,
): string {
  return text.replace(pattern, () => {
    stats[key] += 1;
    return replacement;
  });
}

export function sanitizeText(raw: string, stats = emptyStats()): string {
  let text = raw;

  // Replace the complete OMP-owned conventions section. This intentionally
  // absorbs future wording changes inside the stable structural boundary.
  text = replaceCounted(
    text,
    /<system[-_]conventions\b[^>]*>[\s\S]{0,12000}?<\/system[-_]conventions\s*>/gi,
    CANONICAL_CONVENTIONS,
    stats,
    "conventionsBlocks",
  );

  // OMP 18.2.8 can emit the RFC sentence without a wrapper. Keep this bounded
  // to one line and require both an RFC citation and normative vocabulary.
  text = replaceCounted(
    text,
    /\bRFC\s+(?:2119|8174)\b[^\r\n]{0,400}\b(?:MUST|REQUIRED|SHOULD|RECOMMENDED|MAY|OPTIONAL)\b[^\r\n]{0,400}(?:\.|$)/gi,
    "Requirement terminology: MUST means mandatory, SHOULD means recommended, and MAY means optional.",
    stats,
    "standaloneRfcClauses",
  );

  const structural: Array<[RegExp, string]> = [
    [/<(\/?)system[-_]directive>/gi, "<$1instructions>"],
    [/<(\/?)critical>/gi, "<$1important>"],
  ];
  for (const [pattern, replacement] of structural) {
    text = replaceCounted(text, pattern, replacement, stats, "structuralTags");
  }

  const identifiers: Array<[RegExp, string]> = [
    [/Oh My Pi coding harness/gi, "AI coding assistant"],
    [/Oh My Pi/gi, "coding assistant"],
    [/omp Live/gi, "coding assistant live"],
  ];
  for (const [pattern, replacement] of identifiers) {
    text = replaceCounted(text, pattern, replacement, stats, "harnessIdentifiers");
  }

  return text;
}

const REMOVED_KEYS = new Set(["used_claude", "used_claude_conservative"]);

export function sanitizePayload(jsonText: string): { body: string; stats: SanitizeStats } {
  const stats = emptyStats();
  try {
    const parsed = JSON.parse(jsonText);

    if (parsed && !Array.isArray(parsed) && typeof parsed === "object" && "requestType" in parsed) {
      delete (parsed as Record<string, unknown>).requestType;
      stats.removedFields += 1;
    }

    const clean = (value: unknown): unknown => {
      if (typeof value === "string") return sanitizeText(value, stats);
      if (Array.isArray(value)) return value.map(clean);
      if (value && typeof value === "object") {
        const output: Record<string, unknown> = {};
        for (const [key, child] of Object.entries(value)) {
          if (REMOVED_KEYS.has(key)) {
            stats.removedFields += 1;
            continue;
          }
          output[key] = clean(child);
        }
        return output;
      }
      return value;
    };

    return { body: JSON.stringify(clean(parsed)), stats };
  } catch {
    return { body: sanitizeText(jsonText, stats), stats };
  }
}
