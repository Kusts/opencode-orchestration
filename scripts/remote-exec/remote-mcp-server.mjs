#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';
import { invokeDirectExecution } from './direct-executor.mjs';

const project = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);
const executionId = z.string().uuid();
const timeoutSeconds = z.number().int().min(1).max(86400).default(300);

export const remoteLinuxSchema = z.object({
  project,
  executionId,
  command: z.string().min(1).max(32768),
  workingDirectory: z.string().min(1).max(4096).default('.'),
  timeoutSeconds,
}).strict();

export const remoteDockerSchema = z.object({
  project,
  executionId,
  command: z.array(z.string().min(1).max(8192)).min(1).max(128),
  workingDirectory: z.string().min(1).max(4096).default(process.cwd()),
  timeoutSeconds,
}).strict();

function safeErrorCode(error) {
  const code = String(error?.message ?? 'REMOTE_DIRECT_ERROR');
  return /^[A-Z0-9_]{1,80}$/.test(code) ? code : 'REMOTE_DIRECT_ERROR';
}

export function createServer() {
  const server = new McpServer({ name: 'remote-exec', version: '0.2.0' });
  server.registerTool('remote-linux', {
    description: 'Run one Linux shell command as dev-exec on the fixed contabo-dev-exec alias. No local daemon or WSL fallback.',
    inputSchema: remoteLinuxSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  }, async (args, context) => {
    try {
      const result = await invokeDirectExecution({
        backend: 'remote-linux',
        project: args.project,
        executionId: args.executionId,
        command: args.command,
        workingDirectory: args.workingDirectory,
        timeoutSeconds: args.timeoutSeconds,
      }, { signal: context?.mcpReq?.signal });
      return {
        isError: result.status !== 'PASS',
        content: [{ type: 'text', text: JSON.stringify(result) }],
      };
    } catch (error) {
      return {
        isError: true,
        content: [{ type: 'text', text: safeErrorCode(error) }],
      };
    }
  });
  server.registerTool('remote-docker', {
    description: 'Run Docker against the fixed contabo-dev-rootless Docker Context (SSH as dev-exec to the Rootless socket). Docker builds can use files in the local workingDirectory; no local daemon or WSL is used.',
    inputSchema: remoteDockerSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  }, async (args, context) => {
    try {
      const result = await invokeDirectExecution({
        backend: 'remote-docker',
        project: args.project,
        executionId: args.executionId,
        command: args.command,
        workingDirectory: args.workingDirectory,
        timeoutSeconds: args.timeoutSeconds,
      }, { signal: context?.mcpReq?.signal });
      return {
        isError: result.status !== 'PASS',
        content: [{ type: 'text', text: JSON.stringify(result) }],
      };
    } catch (error) {
      return {
        isError: true,
        content: [{ type: 'text', text: safeErrorCode(error) }],
      };
    }
  });
  return server;
}

import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    void serveStdio(createServer);
  } catch (error) {
    console.error(safeErrorCode(error));
    process.exitCode = 2;
  }
}
