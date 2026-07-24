// The canonical agents the plugin ships. SINGLE SOURCE OF TRUTH, mirroring
// CANONICAL_SKILLS: the agents directory listing, the Claude plugin manifest,
// and the published package files list are all validated against this one list,
// so an agent can never be shipped on one surface and silently dropped from
// another.
//
// The three form one loop: `use-cases-updater` keeps the matrix honest against
// the code, `use-cases-demo-prep` stages a demo from it, `use-cases-demo`
// performs that demo and records the evidence.
export const CANONICAL_AGENTS = ["use-cases-updater", "use-cases-demo-prep", "use-cases-demo"] as const;

export type CanonicalAgent = (typeof CANONICAL_AGENTS)[number];
