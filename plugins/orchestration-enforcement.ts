// Dual-runtime export for the orchestration enforcement plugin.
// Documented shape (V1 >= 1.18.29, V2): the default export carries BOTH
//   { id, setup }  -> read by the V2 host (server() ignored)
//   { server }      -> called by the V1 host (id/setup ignored)
// This module has NO runtime imports of either package: both adapters use
// `import type` only (erased at build), so the emitted bundle references
// neither @opencode-ai/plugin nor @opencode/plugin. The V1 path never
// loads V2 APIs and vice versa.
import { OrchestrationEnforcement as V1Plugin } from "./orchestration-enforcement/v1";
import { V2_ID, V2Plugin } from "./orchestration-enforcement/v2";

// V1 entry: the host calls server() to obtain the V1 plugin. Called with
// a context, it behaves like the V1 plugin factory directly (returns the
// hooks); called without one, it returns the factory for the host to
// invoke. Both call conventions are supported because the exact V1
// dual-export invocation (server() vs server(ctx)) is confirmed only by
// real-host smoke (Phase 5/8); this branching keeps both working.
async function server(ctx?: any): Promise<any> {
  if (ctx === undefined) return V1Plugin;
  return V1Plugin(ctx);
}

async function setup(ctx: any): Promise<any> {
  return V2Plugin.setup(ctx);
}

const DualExport = {
  id: V2_ID,
  setup,
  server,
};

export default DualExport;

// Back-compat: the repo harness and docs import these names from this path.
export { OrchestrationEnforcement } from "./orchestration-enforcement/v1";
export { __orchestrationEnforcementTest } from "./orchestration-enforcement/v1";
export { V2_ID } from "./orchestration-enforcement/v2";

// Phase 28 slice 2: public MCP transport envelope for the integration
// layer (calls ALREADY classified as MCP). Default is shadow-only;
// enforcement requires explicit configureMcpTransport opt-in. V1 has
// no tool-interception surface, so under V1 the envelope is available
// here for direct use with identical semantics (documented parity:
// observe/skip, never silent enforcement, never a crash).
export {
  __mcpTransportTest,
  classifyMcpTool,
  configureMcpTransport,
  effectiveMcpMode,
  getMcpCircuitSnapshot,
  getMcpTransportConfig,
  mcpResultGrantsAuthority,
  normalizeMcpClass,
  normalizeMcpCriticality,
  normalizeMcpTurn,
  observeMcpBeforeExecute,
  pendingMcpDeadlines,
  resetMcpTransport,
  resolveMcpPolicy,
  runMcpGuarded,
  setMcpPolicyFileReader,
} from "./orchestration-enforcement/shared/mcp-transport";
