#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';
import { invokeDirectExecution } from './direct-executor.mjs';
import { createDirectReadonlyRequest, DIRECT_READONLY_OPERATIONS } from './direct-operations.mjs';

function createServer() {
  const server = new McpServer({ name: 'contabo-dev-exec-readonly', version: '0.2.0' });
  for (const [operation, definition] of Object.entries(DIRECT_READONLY_OPERATIONS)) {
    server.registerTool(`contabo_${operation}`, {
      description: `${definition.description} This MCP route is read-only.`,
      inputSchema: z.object({
        project: z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/).default('diagnostic'),
        timeoutSeconds: z.number().int().min(1).max(300).default(30),
      }),
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    }, async (args, context) => {
      try {
        const result = await invokeDirectExecution(createDirectReadonlyRequest(operation, args), {
          signal: context?.mcpReq?.signal,
        });
        return {
          isError: result.status !== 'PASS',
          content: [{ type: 'text', text: JSON.stringify(result) }],
        };
      } catch (error) {
        const code = String(error?.message ?? 'REMOTE_DIRECT_ERROR');
        return {
          isError: true,
          content: [{ type: 'text', text: /^[A-Z0-9_]{1,80}$/.test(code) ? code : 'REMOTE_DIRECT_ERROR' }],
        };
      }
    });
  }
  return server;
}

try {
  if (process.env.REMOTE_EXEC_DIRECT_PROFILE !== 'contabo-dev-exec') throw new Error('REMOTE_DIRECT_PROFILE_NOT_SELECTED');
  void serveStdio(createServer);
} catch (error) {
  const code = String(error?.message ?? 'REMOTE_DIRECT_STARTUP_FAILED');
  console.error(/^[A-Z0-9_]{1,80}$/.test(code) ? code : 'REMOTE_DIRECT_STARTUP_FAILED');
  process.exitCode = 2;
}
