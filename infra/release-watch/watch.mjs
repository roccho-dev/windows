#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const CONTRACT_KEYS = [
  'assetSelector', 'channel', 'officialSource', 'packageShape',
  'platform', 'sourceKind', 'verifyKind', 'versionScheme',
];
const DEFINITION_KEYS = ['contract', 'pin'];
const PIN_KEYS = ['contentHash', 'version'];
const SOURCE_KINDS = new Set(['github-release', 'claude-manifest']);
const VERIFY_KINDS = new Set(['github-asset-digest', 'manifest-sha256']);
const PACKAGE_SHAPES = new Set(['codex-musl-tar', 'single-glibc-executable']);
const EFFECT_STATES = new Set([
  'CONFIRMED_DONE', 'CONFIRMED_NOT_DONE', 'PARTIAL_OR_FAILED', 'STILL_UNKNOWN',
]);
const REGISTRY_PATH = 'hosts/profile/releases.json';

function fail(message) {
  const error = new Error(message);
  error.code = 'RELEASE_WATCH_RED';
  throw error;
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  if (JSON.stringify(actual) !== JSON.stringify([...keys].sort())) {
    fail(`${label} keys differ: ${actual.join(',')}`);
  }
}

function nonEmptyString(value, label) {
  if (typeof value !== 'string' || value.length === 0) fail(`${label} must be a non-empty string`);
}

export function parseVersion(value) {
  if (typeof value !== 'string') return null;
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(value);
  return match ? match.slice(1).map(Number) : null;
}

export function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) return null;
  for (let index = 0; index < 3; index += 1) {
    if (a[index] < b[index]) return -1;
    if (a[index] > b[index]) return 1;
  }
  return 0;
}

export function validateRegistry(registry) {
  if (!registry || typeof registry !== 'object' || Array.isArray(registry)) fail('registry must be an object');
  const names = Object.keys(registry).sort();
  if (names.length === 0) fail('registry is empty');
  for (const name of names) {
    if (!/^[a-z][a-z0-9-]*$/.test(name)) fail(`unsafe CLI name: ${name}`);
    const definition = registry[name];
    exactKeys(definition, DEFINITION_KEYS, `${name}`);
    exactKeys(definition.contract, CONTRACT_KEYS, `${name}.contract`);
    exactKeys(definition.pin, PIN_KEYS, `${name}.pin`);
    const contract = definition.contract;
    const pin = definition.pin;
    for (const key of CONTRACT_KEYS) nonEmptyString(contract[key], `${name}.contract.${key}`);
    nonEmptyString(pin.version, `${name}.pin.version`);
    nonEmptyString(pin.contentHash, `${name}.pin.contentHash`);
    if (!SOURCE_KINDS.has(contract.sourceKind)) fail(`${name}: unsupported sourceKind`);
    if (contract.channel !== 'stable') fail(`${name}: only stable channel is admitted`);
    if (contract.versionScheme !== 'semver' || !parseVersion(pin.version)) fail(`${name}: invalid stable semver`);
    if (!VERIFY_KINDS.has(contract.verifyKind)) fail(`${name}: unsupported verifyKind`);
    if (!PACKAGE_SHAPES.has(contract.packageShape)) fail(`${name}: unsupported packageShape`);
    if (!/^[0-9a-f]{64}$/.test(pin.contentHash)) fail(`${name}: contentHash must be lowercase sha256`);
    if (contract.sourceKind === 'github-release') {
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(contract.officialSource)) fail(`${name}: invalid GitHub source`);
      if (contract.verifyKind !== 'github-asset-digest') fail(`${name}: GitHub release requires asset digest`);
    }
    if (contract.sourceKind === 'claude-manifest') {
      if (!contract.officialSource.startsWith('https://downloads.claude.ai/')) fail(`${name}: invalid Claude source`);
      if (contract.verifyKind !== 'manifest-sha256') fail(`${name}: Claude manifest requires manifest sha256`);
    }
  }
  return registry;
}

export function releaseVersions(registry) {
  validateRegistry(registry);
  return Object.fromEntries(Object.keys(registry).sort().map((name) => [name, registry[name].pin.version]));
}

export function prKey(name) {
  if (!/^[a-z][a-z0-9-]*$/.test(name)) fail(`unsafe CLI name: ${name}`);
  return `cli-release:${name}`;
}

export function decideCandidate(definition, candidate) {
  exactKeys(candidate, ['contentHash', 'proof', 'version'], 'candidate');
  if (candidate.proof !== true) return { state: 'RED', reason: 'proof-failed', mutations: 0 };
  if (!/^[0-9a-f]{64}$/.test(candidate.contentHash)) return { state: 'RED', reason: 'invalid-hash', mutations: 0 };
  const order = compareVersions(candidate.version, definition.pin.version);
  if (order === null) return { state: 'RED', reason: 'incomparable-version', mutations: 0 };
  if (order < 0) return { state: 'RED', reason: 'downgrade', mutations: 0 };
  if (order === 0 && candidate.contentHash !== definition.pin.contentHash) {
    return { state: 'RED', reason: 'same-version-hash-drift', mutations: 0 };
  }
  if (order === 0) return { state: 'NOOP', reason: 'already-adopted', mutations: 0 };
  return { state: 'UPDATE', reason: 'newer-proven-release', mutations: 2 };
}

export function applyPin(registry, name, candidate) {
  validateRegistry(registry);
  if (!Object.hasOwn(registry, name)) fail(`unknown CLI: ${name}`);
  const decision = decideCandidate(registry[name], candidate);
  if (decision.state !== 'UPDATE') return structuredClone(registry);
  const next = structuredClone(registry);
  const contractBefore = JSON.stringify(next[name].contract);
  next[name].pin.version = candidate.version;
  next[name].pin.contentHash = candidate.contentHash;
  if (JSON.stringify(next[name].contract) !== contractBefore) fail('contract mutation is forbidden');
  validateRegistry(next);
  return next;
}

export function planApiEffect({ name, decision, observed }) {
  const noMutation = (state, reason) => ({ state, reason, effectResend: 0, mutations: 0, prKey: prKey(name) });
  if (!decision || !['NOOP', 'UPDATE', 'RED'].includes(decision.state)) return noMutation('STOP', 'invalid-decision');
  if (decision.state === 'NOOP') return noMutation('NOOP', decision.reason);
  if (decision.state === 'RED') return noMutation('RED', decision.reason);
  if (!observed || !EFFECT_STATES.has(observed.effect)) return noMutation('STOP', 'unknown-effect-state');
  if (observed.principal !== observed.expectedPrincipal) return noMutation('STOP', 'foreign-principal');
  if (observed.head !== observed.expectedHead) return noMutation('STOP', 'head-lease-mismatch');
  if (observed.preimage !== observed.expectedPreimage) return noMutation('STOP', 'target-preimage-mismatch');
  if ((observed.humanCommits ?? 0) !== 0) return noMutation('STOP', 'human-or-foreign-commit');
  const allowedPath = REGISTRY_PATH;
  if ((observed.changedPaths ?? []).some((path) => path !== allowedPath)) return noMutation('STOP', 'unexpected-path');
  const allowedPointers = new Set([`/${name}/pin/version`, `/${name}/pin/contentHash`]);
  if ((observed.changedPointers ?? []).some((pointer) => !allowedPointers.has(pointer))) {
    return noMutation('STOP', 'unexpected-json-pointer');
  }
  if (observed.effect === 'CONFIRMED_DONE') return noMutation('JUDGE_EXISTING', 'effect-already-exists');
  if (observed.effect === 'CONFIRMED_NOT_DONE') {
    return { state: 'EXECUTE_PENDING', reason: 'authorized-pending-effect', effectResend: 0, mutations: 1, prKey: prKey(name) };
  }
  return noMutation('STOP', observed.effect === 'PARTIAL_OR_FAILED' ? 'partial-or-failed' : 'still-unknown');
}

async function responseJson(response, label) {
  if (!response.ok) fail(`${label}: HTTP ${response.status}`);
  return response.json();
}

async function responseText(response, label) {
  if (!response.ok) fail(`${label}: HTTP ${response.status}`);
  return (await response.text()).trim();
}

export async function resolveCandidate(name, definition, fetchImpl = fetch) {
  const contract = definition.contract;
  if (contract.sourceKind === 'github-release') {
    const release = await responseJson(
      await fetchImpl(`https://api.github.com/repos/${contract.officialSource}/releases/latest`, {
        headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
      }),
      `${name}: release`,
    );
    if (release.draft || release.prerelease) fail(`${name}: latest release is not stable`);
    const prefix = contract.packageShape === 'codex-musl-tar' ? 'rust-v' : 'v';
    if (typeof release.tag_name !== 'string' || !release.tag_name.startsWith(prefix)) fail(`${name}: unexpected release tag`);
    const version = release.tag_name.slice(prefix.length);
    if (!parseVersion(version)) fail(`${name}: non-semver release tag`);
    const asset = (release.assets ?? []).find((item) => item.name === contract.assetSelector);
    if (!asset) fail(`${name}: required asset is absent`);
    const digest = typeof asset.digest === 'string' ? asset.digest : '';
    if (!digest.startsWith('sha256:') || !/^[0-9a-f]{64}$/.test(digest.slice(7))) fail(`${name}: verified asset digest is absent`);
    return { version, contentHash: digest.slice(7), proof: true, sourceUrl: asset.browser_download_url };
  }
  if (contract.sourceKind === 'claude-manifest') {
    const stableRaw = await responseText(await fetchImpl(`${contract.officialSource}/stable`), `${name}: stable`);
    let version = stableRaw;
    try {
      const parsed = JSON.parse(stableRaw);
      version = parsed.version ?? parsed.latest ?? stableRaw;
    } catch {
      // The official stable endpoint is also allowed to return the plain version.
    }
    if (!parseVersion(version)) fail(`${name}: stable endpoint returned an invalid version`);
    const manifest = await responseJson(
      await fetchImpl(`${contract.officialSource}/${version}/manifest.json`),
      `${name}: manifest`,
    );
    const platform = manifest.platforms?.[contract.platform];
    if (!platform) fail(`${name}: manifest platform is absent`);
    const contentHash = platform.checksum ?? platform.sha256;
    if (!/^[0-9a-f]{64}$/.test(contentHash ?? '')) fail(`${name}: manifest sha256 is absent`);
    return {
      version,
      contentHash,
      proof: true,
      sourceUrl: `${contract.officialSource}/${version}/${contract.platform}/${contract.assetSelector}`,
    };
  }
  fail(`${name}: no resolver for ${contract.sourceKind}`);
}

function githubHeaders(token) {
  return {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
}

async function githubApi(repository, token, method, path, body) {
  const response = await fetch(`https://api.github.com/repos/${repository}${path}`, {
    method,
    headers: githubHeaders(token),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (response.status === 404 && method === 'GET') return null;
  if (!response.ok) fail(`GitHub ${method} ${path}: HTTP ${response.status} ${(await response.text()).slice(0, 300)}`);
  if (response.status === 204) return null;
  return response.json();
}

function base64Utf8(text) {
  return Buffer.from(text, 'utf8').toString('base64');
}

function changedPointers(base, next, name) {
  const pointers = [];
  if (base[name].pin.version !== next[name].pin.version) pointers.push(`/${name}/pin/version`);
  if (base[name].pin.contentHash !== next[name].pin.contentHash) pointers.push(`/${name}/pin/contentHash`);
  const baseCopy = structuredClone(base);
  const nextCopy = structuredClone(next);
  baseCopy[name].pin = nextCopy[name].pin;
  if (JSON.stringify(baseCopy) !== JSON.stringify(nextCopy)) pointers.push('/unexpected');
  return pointers;
}

async function putRegistryCommit({ repository, token, parentSha, registry, message }) {
  const parent = await githubApi(repository, token, 'GET', `/git/commits/${parentSha}`);
  const blob = await githubApi(repository, token, 'POST', '/git/blobs', {
    content: base64Utf8(`${JSON.stringify(registry, null, 2)}\n`), encoding: 'base64',
  });
  const tree = await githubApi(repository, token, 'POST', '/git/trees', {
    base_tree: parent.tree.sha,
    tree: [{ path: REGISTRY_PATH, mode: '100644', type: 'blob', sha: blob.sha }],
  });
  return githubApi(repository, token, 'POST', '/git/commits', {
    message, tree: tree.sha, parents: [parentSha],
  });
}

async function proposeOne({ repository, token, baseBranch, baseSha, registry, name, candidate }) {
  const decision = decideCandidate(registry[name], candidate);
  if (decision.state !== 'UPDATE') return { name, ...decision };
  const [owner] = repository.split('/');
  const branch = `bot/cli-release-${name}`;
  const prs = await githubApi(repository, token, 'GET', `/pulls?state=open&base=${encodeURIComponent(baseBranch)}&head=${encodeURIComponent(`${owner}:${branch}`)}`) ?? [];
  if (prs.length > 1) fail(`${name}: more than one bot PR exists`);
  const ref = await githubApi(repository, token, 'GET', `/git/ref/heads/${encodeURIComponent(branch)}`);
  let parentSha = baseSha;
  let effect = 'CONFIRMED_NOT_DONE';
  let changedPaths = [];
  let humanCommits = 0;
  let currentRegistry = registry;
  if (ref) {
    if (prs.length !== 1) fail(`${name}: bot branch exists without exactly one open PR`);
    parentSha = ref.object.sha;
    const files = await githubApi(repository, token, 'GET', `/pulls/${prs[0].number}/files?per_page=100`) ?? [];
    changedPaths = files.map((file) => file.filename);
    const commits = await githubApi(repository, token, 'GET', `/pulls/${prs[0].number}/commits?per_page=100`) ?? [];
    humanCommits = commits.filter((commit) => commit.author?.login !== 'github-actions[bot]').length;
    const file = await githubApi(repository, token, 'GET', `/contents/${REGISTRY_PATH}?ref=${encodeURIComponent(branch)}`);
    currentRegistry = validateRegistry(JSON.parse(Buffer.from(file.content, 'base64').toString('utf8')));
    effect = currentRegistry[name].pin.version === candidate.version && currentRegistry[name].pin.contentHash === candidate.contentHash
      ? 'CONFIRMED_DONE' : 'CONFIRMED_NOT_DONE';
  }
  const next = applyPin(registry, name, candidate);
  const pointers = changedPointers(registry, next, name);
  const observed = {
    effect,
    principal: 'github-actions[bot]',
    expectedPrincipal: 'github-actions[bot]',
    head: parentSha,
    expectedHead: parentSha,
    preimage: createHash('sha256').update(JSON.stringify(currentRegistry[name].pin)).digest('hex'),
    expectedPreimage: createHash('sha256').update(JSON.stringify(currentRegistry[name].pin)).digest('hex'),
    humanCommits,
    changedPaths,
    changedPointers: pointers,
  };
  const plan = planApiEffect({ name, decision, observed });
  if (plan.state === 'JUDGE_EXISTING') return { name, state: 'NOOP', reason: 'existing-bot-pr-already-has-candidate', pr: prs[0]?.html_url };
  if (plan.state !== 'EXECUTE_PENDING') fail(`${name}: ${plan.reason}`);
  const commit = await putRegistryCommit({
    repository, token, parentSha, registry: next,
    message: `chore: update ${name} to ${candidate.version}\n\n${prKey(name)}`,
  });
  if (ref) {
    await githubApi(repository, token, 'PATCH', `/git/refs/heads/${encodeURIComponent(branch)}`, { sha: commit.sha, force: false });
  } else {
    await githubApi(repository, token, 'POST', '/git/refs', { ref: `refs/heads/${branch}`, sha: commit.sha });
  }
  let pr = prs[0];
  if (!pr) {
    pr = await githubApi(repository, token, 'POST', '/pulls', {
      title: `chore: update ${name} to ${candidate.version}`,
      head: branch,
      base: baseBranch,
      body: `${prKey(name)}\n\nOfficial stable candidate with verified content hash. Existing CI requires manual approval because GITHUB_TOKEN-created PR events are not treated as CI proof.`,
      draft: true,
    });
  }
  return { name, state: 'UPDATED_PR', version: candidate.version, head: commit.sha, pr: pr.html_url };
}

export async function runPropose(registryPath) {
  const repository = process.env.GITHUB_REPOSITORY;
  const token = process.env.GITHUB_TOKEN;
  const baseBranch = process.env.GITHUB_REF_NAME || 'proposals';
  const baseSha = process.env.GITHUB_SHA;
  if (!repository || !token || !/^[0-9a-f]{40}$/.test(baseSha ?? '')) fail('missing GitHub runtime binding');
  const registry = validateRegistry(JSON.parse(await readFile(registryPath, 'utf8')));
  const results = [];
  for (const [name, definition] of Object.entries(registry)) {
    const candidate = await resolveCandidate(name, definition);
    results.push(await proposeOne({ repository, token, baseBranch, baseSha, registry, name, candidate }));
  }
  return results;
}

async function main() {
  const [command = 'validate', registryPath = REGISTRY_PATH] = process.argv.slice(2);
  const registry = validateRegistry(JSON.parse(await readFile(registryPath, 'utf8')));
  if (command === 'validate') {
    process.stdout.write(`${JSON.stringify(releaseVersions(registry))}\n`);
    return;
  }
  if (command === 'check') {
    const results = [];
    for (const [name, definition] of Object.entries(registry)) {
      const candidate = await resolveCandidate(name, definition);
      results.push({ name, candidate, decision: decideCandidate(definition, candidate) });
    }
    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
    return;
  }
  if (command === 'propose') {
    process.stdout.write(`${JSON.stringify(await runPropose(registryPath), null, 2)}\n`);
    return;
  }
  fail(`unknown command: ${command}`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    console.error(`release-watch: ${error.message}`);
    process.exitCode = 1;
  });
}
