import { randomBytes } from 'node:crypto';
import { spawn as nodeSpawn } from 'node:child_process';

const HOST_ALIAS = 'contabo-dev-exec';
const DOCKER_CONTEXT = 'contabo-dev-rootless';
const MAX_COMMAND_LENGTH = 32_768;
const MAX_DOCKER_ARGS = 128;
const MAX_DOCKER_ARG_LENGTH = 8_192;
const MAX_OUTPUT_BYTES = 1_048_576;
const MIN_TIMEOUT_SECONDS = 1;
const MAX_TIMEOUT_SECONDS = 86_400;

const ERROR_CODES = Object.freeze({
  timeout: 'REMOTE_TIMEOUT',
  transport: 'SSH_TRANSPORT_ERROR',
  exit: 'REMOTE_EXIT_NONZERO',
  invalid: 'REMOTE_RESULT_INVALID',
});

function validateRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('REMOTE_REQUEST_INVALID');
  const { backend, project, executionId, timeoutSeconds = 300 } = request;
  if (!['remote-linux', 'remote-docker'].includes(backend)) throw new Error('REMOTE_BACKEND_INVALID');
  if (typeof project !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(project)) throw new Error('REMOTE_PROJECT_INVALID');
  if (typeof executionId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(executionId)) {
    throw new Error('REMOTE_EXECUTION_ID_INVALID');
  }
  if (!Number.isSafeInteger(timeoutSeconds) || timeoutSeconds < MIN_TIMEOUT_SECONDS || timeoutSeconds > MAX_TIMEOUT_SECONDS) {
    throw new Error('REMOTE_TIMEOUT_INVALID');
  }

  if (backend === 'remote-linux') {
    if (typeof request.command !== 'string' || request.command.length < 1 || request.command.length > MAX_COMMAND_LENGTH || request.command.includes('\0')) {
      throw new Error('REMOTE_COMMAND_INVALID');
    }
    if (typeof request.workingDirectory !== 'string' || request.workingDirectory.length < 1 || request.workingDirectory.length > 4_096 || /[\0\r\n]/.test(request.workingDirectory)) {
      throw new Error('REMOTE_WORKDIR_INVALID');
    }
    const portable = request.workingDirectory.replaceAll('\\', '/');
    if (portable.startsWith('/') || /^[A-Za-z]:/.test(portable) || portable.split('/').some((part) => part === '..')) {
      throw new Error('REMOTE_WORKDIR_INVALID');
    }
  } else {
    if (!Array.isArray(request.command) || request.command.length < 1 || request.command.length > MAX_DOCKER_ARGS ||
        request.command.some((arg) => typeof arg !== 'string' || arg.length > MAX_DOCKER_ARG_LENGTH || arg.includes('\0'))) {
      throw new Error('REMOTE_DOCKER_ARGS_INVALID');
    }
    const dockerArgs = request.command;
    const retargetsDocker = dockerArgs.some((arg) =>
      arg === '--context' || arg.startsWith('--context=') || arg === '-c' || arg.startsWith('-c=') ||
      (arg.startsWith('-c') && !arg.startsWith('--')) ||
      arg === '--host' || arg.startsWith('--host=') || arg === '-H' || arg.startsWith('-H') ||
      arg === '--config' || arg.startsWith('--config=') ||
      arg === '--tls' || arg.startsWith('--tls=') || arg.startsWith('--tlscacert') ||
      arg.startsWith('--tlscert') || arg.startsWith('--tlskey') || arg.startsWith('--tlsverify'));
    // Context/socket management can persistently change the endpoint behind the
    // fixed Rootless target. The caller cannot select profile, context, socket,
    // host, or config: remote-docker always targets the fixed Rootless dev-exec.
    const selectsBuilder = dockerArgs[0] === 'buildx' || dockerArgs.some((arg) =>
      arg === '--builder' || arg.startsWith('--builder=') || arg === '-b' || arg.startsWith('-b='));
    if (retargetsDocker || dockerArgs[0] === 'context' || selectsBuilder) {
      throw new Error('REMOTE_DOCKER_TARGET_OVERRIDE');
    }
    if (dockerArgs[0].length === 0 || dockerArgs[0].startsWith('-')) {
      throw new Error('REMOTE_DOCKER_GLOBAL_OPTIONS_FORBIDDEN');
    }
    for (const forbidden of ['dockerProfile', 'dockerContext', 'dockerHost', 'dockerSocket', 'dockerConfig', 'context', 'host', 'socket']) {
      if (Object.hasOwn(request, forbidden)) {
        throw new Error('REMOTE_DOCKER_TARGET_OVERRIDE');
      }
    }
    const workingDirectory = request.workingDirectory ?? process.cwd();
    if (typeof workingDirectory !== 'string' || workingDirectory.length < 1 || workingDirectory.length > 4096 || /[\0\r\n]/.test(workingDirectory)) {
      throw new Error('REMOTE_WORKDIR_INVALID');
    }
    return { ...request, executionId: executionId.toLowerCase(), timeoutSeconds, workingDirectory };
  }
  return { ...request, executionId: executionId.toLowerCase(), timeoutSeconds };
}

function makeResult(request, status, exitCode, stdout, stderr, startedAt, errorCode = '') {
  return {
    schemaVersion: 1,
    backend: request.backend,
    executionId: request.executionId,
    status,
    exitCode,
    stdout,
    stderr,
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    errorCode,
  };
}

function base64Utf8(value) {
  return Buffer.from(value, 'utf8').toString('base64');
}

function createRemoteScript(request) {
  const markerNonce = randomBytes(24).toString('hex');
  const command64 = base64Utf8(request.command);
  const directory64 = base64Utf8(request.workingDirectory);
  const marker = `__REMOTE_EXEC_RESULT_${request.executionId}_${markerNonce}__`;
  const script = [
    'set +e',
    `marker='${marker}'`,
    `timeout_seconds='${request.timeoutSeconds}'`,
    `command64='${command64}'`,
    `directory64='${directory64}'`,
    "working_directory=$(printf '%s' \"$directory64\" | base64 --decode) || exit 70",
    "command_text=$(printf '%s' \"$command64\" | base64 --decode) || exit 70",
    'cd -- "$working_directory"',
    'cd_status=$?',
    'if [ "$cd_status" -ne 0 ]; then',
    '  printf \'\\n%s:%s\\n\' "$marker" "$cd_status" >&2',
    '  exit 0',
    'fi',
    'timeout --foreground --signal=TERM --kill-after=5s "${timeout_seconds}s" bash --noprofile --norc -c "$command_text"',
    'command_status=$?',
    'printf \'\\n%s:%s\\n\' "$marker" "$command_status" >&2',
    'exit 0',
    '',
  ].join('\n');
  return { script, marker };
}

function boundedAppend(target, length, chunk) {
  const incoming = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
  const remaining = MAX_OUTPUT_BYTES - length;
  const copied = Math.min(remaining, incoming.length);
  if (copied > 0) incoming.copy(target, length, 0, copied);
  return { length: length + copied, overflow: incoming.length > copied };
}

function decodeBoundedUtf8(buffer, length) {
  const decoded = buffer.subarray(0, length).toString('utf8');
  let byteLength = 0;
  let end = 0;
  for (const codePoint of decoded) {
    const size = Buffer.byteLength(codePoint, 'utf8');
    if (byteLength + size > MAX_OUTPUT_BYTES) break;
    byteLength += size;
    end += codePoint.length;
  }
  return decoded.slice(0, end);
}

async function runChild({ executable, args, input, timeoutSeconds, signal, env, cwd, spawnImpl }) {
  const startedAt = new Date();
  return new Promise((resolve) => {
    const stdoutBuffer = Buffer.alloc(MAX_OUTPUT_BYTES);
    const stderrBuffer = Buffer.alloc(MAX_OUTPUT_BYTES);
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let overflow = false;
    let settled = false;
    let spawnError = false;
    let stdinError = false;
    let sentInput = false;
    let timedOut = false;
    let cancelled = false;
    let child;
    let timer;

    const finish = (processCode, processSignal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      resolve({
        stdout: decodeBoundedUtf8(stdoutBuffer, stdoutBytes),
        stderr: decodeBoundedUtf8(stderrBuffer, stderrBytes),
        processCode, processSignal, spawnError, stdinError, overflow, sentInput, timedOut, cancelled, startedAt,
      });
    };
    const stop = (kind) => {
      if (settled) return;
      if (kind === 'timeout') timedOut = true;
      if (kind === 'cancel') cancelled = true;
      try { child?.kill(); } catch { /* child may already have exited */ }
      setTimeout(() => finish(null, kind === 'timeout' ? 'SIGTERM' : 'SIGINT'), 50).unref?.();
    };
    const onAbort = () => stop('cancel');

    try {
      child = spawnImpl(executable, args, {
        shell: false,
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
        env,
        ...(cwd ? { cwd } : {}),
      });
    } catch {
      spawnError = true;
      finish(null, null);
      return;
    }

    timer = setTimeout(() => stop('timeout'), timeoutSeconds * 1_000);
    timer.unref?.();
    if (signal?.aborted) onAbort();
    else signal?.addEventListener('abort', onAbort, { once: true });

    child.stdout?.on('data', (chunk) => {
      const result = boundedAppend(stdoutBuffer, stdoutBytes, chunk);
      stdoutBytes = result.length;
      if (result.overflow) {
        overflow = true;
        stop('overflow');
      }
    });
    child.stderr?.on('data', (chunk) => {
      const result = boundedAppend(stderrBuffer, stderrBytes, chunk);
      stderrBytes = result.length;
      if (result.overflow) {
        overflow = true;
        stop('overflow');
      }
    });
    child.once('error', () => {
      spawnError = true;
      finish(null, null);
    });
    child.stdin?.once('error', () => {
      stdinError = true;
      try { child.kill(); } catch { /* child may already have exited */ }
    });
    child.once('close', (code, processSignal) => finish(code, processSignal));

    if (input !== undefined) {
      sentInput = true;
      try { child.stdin?.end(input); }
      catch {
        try { child.kill(); } catch { /* child may already have exited */ }
      }
    } else {
      child.stdin?.end();
    }
  });
}

function outputWithoutMarker(stderr, marker) {
  const pattern = new RegExp(`(?:^|\\r?\\n)${marker}:(\\d{1,3})\\r?\\n?$`);
  const match = pattern.exec(stderr);
  if (!match) return { exitCode: null, stderr };
  const markerStart = match.index + (match[0].startsWith('\n') ? 1 : 0);
  const clean = `${stderr.slice(0, markerStart)}${stderr.slice(markerStart).replace(pattern, '').replace(/^\r?\n/, '')}`;
  const exitCode = Number(match[1]);
  if (!Number.isInteger(exitCode) || exitCode < 0 || exitCode > 255) return { exitCode: null, stderr };
  return { exitCode, stderr: clean };
}

function dockerChildEnv(env) {
  const childEnv = { ...env };
  const dockerOverrideNames = new Set([
    'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_TLS',
    'DOCKER_CERT_PATH', 'DOCKER_CONFIG', 'DOCKER_CUSTOM_HEADERS', 'BUILDX_BUILDER',
  ]);
  for (const key of Object.keys(childEnv)) {
    if (dockerOverrideNames.has(key.toUpperCase())) delete childEnv[key];
  }
  return childEnv;
}

function hasTransportFailure(stderr) {
  return /(?:ssh:.*(?:connect|connection)|connection (?:closed|reset|timed out)|unexpected eof|error during connect|failed to connect|context deadline exceeded)/i.test(stderr);
}

/**
 * Execute one remote Linux command or Docker CLI invocation. Linux uses SSH;
 * Docker uses the fixed local Docker Context whose endpoint is the Rootless
 * dev-exec socket over SSH. This lets Docker send a local build context to the
 * VPS without Docker Desktop/WSL or a remote workspace copy. `spawnImpl`,
 * `env`, and executable names are injectable for tests.
 */
export async function invokeDirectExecution(untrustedRequest, options = {}) {
  const request = validateRequest(untrustedRequest);
  const spawnImpl = options.spawnImpl ?? nodeSpawn;
  const platform = options.platform ?? process.platform;
  const env = options.env ?? process.env;
  const sshExecutable = options.sshExecutable ?? (platform === 'win32' ? 'ssh.exe' : 'ssh');
  const dockerExecutable = options.dockerExecutable ?? (platform === 'win32' ? 'docker.exe' : 'docker');
  const signal = options.signal;

  if (signal?.aborted) {
    const startedAt = new Date();
    return makeResult(request, 'UNKNOWN', null, '', '', startedAt, ERROR_CODES.transport);
  }

  if (request.backend === 'remote-linux') {
    const { script, marker } = createRemoteScript(request);
    const run = await runChild({
      executable: sshExecutable,
      args: ['-T', HOST_ALIAS, 'bash', '-s'],
      input: script,
      timeoutSeconds: request.timeoutSeconds + 10,
      signal,
      env,
      spawnImpl,
    });
    if (run.overflow) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.invalid);
    if (run.timedOut) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.timeout);
    if (run.cancelled) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.transport);
    if (run.spawnError || run.stdinError || run.processCode !== 0 || run.processSignal) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.transport);

    const parsed = outputWithoutMarker(run.stderr, marker);
    if (parsed.exitCode === null) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.invalid);
    if (parsed.exitCode === 124 || parsed.exitCode === 137) {
      return makeResult(request, 'UNKNOWN', null, run.stdout, parsed.stderr, run.startedAt, ERROR_CODES.timeout);
    }
    if (parsed.exitCode !== 0) return makeResult(request, 'FAIL', parsed.exitCode, run.stdout, parsed.stderr, run.startedAt, ERROR_CODES.exit);
    return makeResult(request, 'PASS', 0, run.stdout, parsed.stderr, run.startedAt);
  }

  if (request.backend === 'remote-docker') {
    const run = await runChild({
      executable: dockerExecutable,
      args: ['--context', DOCKER_CONTEXT, ...request.command],
      timeoutSeconds: request.timeoutSeconds,
      signal,
      env: dockerChildEnv(env),
      cwd: request.workingDirectory,
      spawnImpl,
    });
    if (run.overflow) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.invalid);
    if (run.timedOut) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.timeout);
    if (run.cancelled || run.spawnError || run.stdinError || run.processSignal || hasTransportFailure(run.stderr)) {
      return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.transport);
    }
    if (!Number.isInteger(run.processCode)) return makeResult(request, 'UNKNOWN', null, run.stdout, run.stderr, run.startedAt, ERROR_CODES.transport);
    if (run.processCode !== 0) return makeResult(request, 'FAIL', run.processCode, run.stdout, run.stderr, run.startedAt, ERROR_CODES.exit);
    return makeResult(request, 'PASS', 0, run.stdout, run.stderr, run.startedAt);
  }

  throw new Error('REMOTE_BACKEND_INVALID');
}

export const DIRECT_EXECUTOR_LIMITS = Object.freeze({
  maxCommandLength: MAX_COMMAND_LENGTH,
  maxDockerArgs: MAX_DOCKER_ARGS,
  maxDockerArgLength: MAX_DOCKER_ARG_LENGTH,
  maxOutputBytesPerStream: MAX_OUTPUT_BYTES,
});
