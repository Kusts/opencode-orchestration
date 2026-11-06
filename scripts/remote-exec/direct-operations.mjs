import { randomUUID } from 'node:crypto';

const PROJECT_PATTERN = /^[a-z0-9][a-z0-9-]{0,62}$/;

export const DIRECT_READONLY_OPERATIONS = Object.freeze({
  host_status: Object.freeze({
    description: 'Read kernel and root filesystem capacity on the Contabo VPS.',
    backend: 'remote-linux',
  }),
  docker_info: Object.freeze({
    description: 'Read summary information from the fixed Rootless dev-exec Docker daemon.',
    backend: 'remote-docker',
  }),
  docker_ps: Object.freeze({
    description: 'List containers on the fixed Rootless dev-exec Docker daemon.',
    backend: 'remote-docker',
  }),
  docker_images: Object.freeze({
    description: 'List images on the fixed Rootless dev-exec Docker daemon.',
    backend: 'remote-docker',
  }),
});

export function createDirectReadonlyRequest(operation, input = {}, executionId = randomUUID()) {
  if (!Object.hasOwn(DIRECT_READONLY_OPERATIONS, operation)) throw new Error('REMOTE_OPERATION_NOT_ALLOWED');
  const project = input.project ?? 'diagnostic';
  if (typeof project !== 'string' || !PROJECT_PATTERN.test(project)) throw new Error('REMOTE_PROJECT_INVALID');
  const timeoutSeconds = input.timeoutSeconds ?? 30;
  if (!Number.isSafeInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 300) {
    throw new Error('REMOTE_TIMEOUT_INVALID');
  }

  const request = {
    schemaVersion: 1,
    backend: DIRECT_READONLY_OPERATIONS[operation].backend,
    project,
    executionId,
    timeoutSeconds,
    workingDirectory: '.',
  };
  if (operation === 'host_status') {
    request.command = 'printf "kernel="; uname -srm; printf "root_available_bytes="; df -B1 --output=avail / | tail -n 1';
  } else if (operation === 'docker_info') {
    request.command = ['info', '--format', 'name={{.Name}} root={{.DockerRootDir}} containers={{.Containers}} running={{.ContainersRunning}} images={{.Images}} engine={{.ServerVersion}} os={{.OperatingSystem}} arch={{.Architecture}} driver={{.Driver}}'];
  } else if (operation === 'docker_ps') {
    request.command = ['ps', '--all', '--format', '{{.ID}}|{{.Image}}|{{.Names}}|{{.Status}}'];
  } else {
    request.command = ['images', '--format', '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}'];
  }
  return request;
}
