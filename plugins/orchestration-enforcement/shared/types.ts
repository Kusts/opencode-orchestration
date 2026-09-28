// Shared kernel types for the dual-runtime enforcement plugin.
// PURE: no imports of any kind. Both adapters (V1/V2) depend on these
// shapes; the runtime packages (@opencode-ai/plugin, @opencode/plugin)
// are only ever referenced via `import type` inside the adapters, so no
// runtime code path ever loads the other generation's API.
export type SessionType = "planner" | "worker" | "unknown";
export type MandateKind = "planner" | "worker" | "neutral";
export type Role = "planner" | "worker" | "neutral";
export type IdentitySource = "session-map" | "input-probe" | "none";
export type Generation = "v1" | "v2";
export type RuntimeId = "v1" | "v2";

export interface SessionEntry {
  parentID?: string;
  agent?: string;
}

export interface RoleResolution {
  role: Role;
  agent: string | undefined;
  source: IdentitySource;
}

export interface InjectionRecord {
  sessionType: SessionType;
  agent: string | undefined;
  mandateKind: MandateKind;
  markerUsed: string;
  session: string | undefined;
  identitySource: IdentitySource;
}
