#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const CONTRACT_KEYS = [
  'assetSelector', 'channel', 'officialSource', 'packageShape', 'platform',
  'proof', 'sourceKind', 'verifyKind', 'versionScheme',
];
const DEFINITION_KEYS = ['contract', 'pin'];
const PIN_KEYS = ['contentHash', 'version'];
const REGISTRY_PATH = 'hosts/profile/releases.json';
const BASE_BRANCH = 'proposals';
const BOT_LOGIN = 'github-actions[bot]';
const PAGE_SIZE = 100;
const MAX_API_PAGES = 100;
const PAGE_META = Symbol('github-page-meta');
const COLLECTION_LIMITS = Object.freeze({
  openPrs: Object.freeze({ maxPages: 1, maxItems: 1 }),
  closedPrs: Object.freeze({ maxPages: 10, maxItems: 1000 }),
  commits: Object.freeze({ maxPages: 3, maxItems: 250 }),
  files: Object.freeze({ maxPages: 30, maxItems: 3000 }),
});
const BOT_GIT_IDENTITY = Object.freeze({
  name: 'github-actions[bot]',
  email: '41898282+github-actions[bot]@users.noreply.github.com',
});
const EFFECT_STATES = new Set([
  'CONFIRMED_DONE', 'CONFIRMED_NOT_DONE', 'PARTIAL_OR_FAILED', 'STILL_UNKNOWN',
]);

function fail(message) {
  const error = new Error(message);
  error.code = 'RELEASE_WATCH_RED';
  throw error;
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) fail(`${label} keys differ: ${actual.join(',')}`);
}

function nonEmptyString(value, label) {
  if (typeof value !== 'string' || value.length === 0) fail(`${label} must be a non-empty string`);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
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

function validateProof(name, contract) {
  if (contract.verifyKind === 'sigstore-bundle') {
    exactKeys(contract.proof, [
      'assetSuffix', 'certificateIdentityPrefix', 'certificateOidcIssuer', 'kind',
    ], `${name}.contract.proof`);
    if (contract.proof.kind !== 'sigstore-bundle') fail(`${name}: proof kind differs`);
    if (contract.proof.assetSuffix !== '.sigstore') fail(`${name}: sigstore suffix differs`);
    if (!contract.proof.certificateIdentityPrefix.startsWith('https://github.com/')) fail(`${name}: unsafe certificate identity`);
    if (contract.proof.certificateOidcIssuer !== 'https://token.actions.githubusercontent.com') fail(`${name}: unsafe certificate issuer`);
    return;
  }
  if (contract.verifyKind === 'gpg-signed-manifest') {
    exactKeys(contract.proof, [
      'keyFingerprint', 'keyUrl', 'kind', 'manifestName', 'signatureName',
    ], `${name}.contract.proof`);
    if (contract.proof.kind !== 'gpg-signed-manifest') fail(`${name}: proof kind differs`);
    if (contract.proof.manifestName !== 'manifest.json' || contract.proof.signatureName !== 'manifest.json.sig') {
      fail(`${name}: manifest proof names differ`);
    }
    if (!contract.proof.keyUrl.startsWith('https://downloads.claude.ai/keys/')) fail(`${name}: unsafe signing key source`);
    if (!/^[0-9A-F]{40}$/.test(contract.proof.keyFingerprint)) fail(`${name}: invalid signing key fingerprint`);
    return;
  }
  fail(`${name}: unsupported verifyKind`);
}

export function validateRegistry(registry) {
  if (!registry || typeof registry !== 'object' || Array.isArray(registry)) fail('registry must be an object');
  const names = Object.keys(registry).sort();
  if (names.length === 0) fail('registry is empty');
  for (const name of names) {
    if (!/^[a-z][a-z0-9-]*$/.test(name)) fail(`unsafe CLI name: ${name}`);
    const definition = registry[name];
    exactKeys(definition, DEFINITION_KEYS, name);
    exactKeys(definition.contract, CONTRACT_KEYS, `${name}.contract`);
    exactKeys(definition.pin, PIN_KEYS, `${name}.pin`);
    const { contract, pin } = definition;
    for (const key of CONTRACT_KEYS.filter((key) => key !== 'proof')) nonEmptyString(contract[key], `${name}.contract.${key}`);
    nonEmptyString(pin.version, `${name}.pin.version`);
    nonEmptyString(pin.contentHash, `${name}.pin.contentHash`);
    if (contract.channel !== 'stable') fail(`${name}: only stable channel is admitted`);
    if (contract.versionScheme !== 'semver' || !parseVersion(pin.version)) fail(`${name}: invalid stable semver`);
    if (!/^[0-9a-f]{64}$/.test(pin.contentHash)) fail(`${name}: contentHash must be lowercase sha256`);
    if (contract.sourceKind === 'github-release') {
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(contract.officialSource)) fail(`${name}: invalid GitHub source`);
      if (contract.packageShape !== 'codex-musl-tar' || contract.verifyKind !== 'sigstore-bundle') fail(`${name}: GitHub release proof differs`);
    } else if (contract.sourceKind === 'claude-manifest') {
      if (!contract.officialSource.startsWith('https://downloads.claude.ai/claude-code-releases')) fail(`${name}: invalid Claude source`);
      if (contract.packageShape !== 'single-glibc-executable' || contract.verifyKind !== 'gpg-signed-manifest') fail(`${name}: Claude proof differs`);
    } else {
      fail(`${name}: unsupported sourceKind`);
    }
    validateProof(name, contract);
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

export function prMarker(name) {
  return `<!-- ${prKey(name)} -->`;
}

function pinOf(candidate) {
  return candidate ? { version: candidate.version, contentHash: candidate.contentHash } : null;
}

function comparePin(left, right) {
  if (!left || !right) return null;
  const order = compareVersions(left.version, right.version);
  if (order === null) return { state: 'RED', reason: 'incomparable-version' };
  if (order === 0 && left.contentHash !== right.contentHash) return { state: 'RED', reason: 'same-version-hash-drift' };
  return { state: 'ORDER', order };
}

/** A=current source, B=existing admitted bot PR pin or null, C=new proven official pin. */
export function decideThreeVersion(definition, candidate, pendingPin = null) {
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) fail('candidate must be an object');
  const allowedCandidateKeys = new Set(['contentHash', 'proof', 'proofReceipt', 'selectedBytes', 'sourceUrl', 'version']);
  const unexpectedCandidateKeys = Object.keys(candidate).filter((key) => !allowedCandidateKeys.has(key));
  if (unexpectedCandidateKeys.length !== 0) fail(`candidate has unexpected keys: ${unexpectedCandidateKeys.sort().join(',')}`);
  for (const key of ['contentHash', 'proof', 'version']) {
    if (!Object.hasOwn(candidate, key)) fail(`candidate missing required key: ${key}`);
  }
  if (candidate.proof !== true) return { state: 'RED', reason: 'proof-failed', mutations: 0, action: 'STOP' };
  if (!parseVersion(candidate.version)) return { state: 'RED', reason: 'incomparable-version', mutations: 0, action: 'STOP' };
  if (!/^[0-9a-f]{64}$/.test(candidate.contentHash)) return { state: 'RED', reason: 'invalid-hash', mutations: 0, action: 'STOP' };
  const A = definition.pin;
  const C = pinOf(candidate);
  const ca = comparePin(C, A);
  if (ca.state === 'RED') return { state: 'RED', reason: ca.reason, mutations: 0, action: 'STOP' };
  if (ca.order < 0) return { state: 'RED', reason: 'C-before-A', mutations: 0, action: 'STOP' };
  if (pendingPin) {
    const ba = comparePin(pendingPin, A);
    if (ba.state === 'RED') return { state: 'RED', reason: `B-${ba.reason}`, mutations: 0, action: 'STOP' };
    if (ba.order < 0) return { state: 'RED', reason: 'B-before-A', mutations: 0, action: 'STOP' };
    const cb = comparePin(C, pendingPin);
    if (cb.state === 'RED') return { state: 'RED', reason: `C-B-${cb.reason}`, mutations: 0, action: 'STOP' };
    if (cb.order < 0) return { state: 'RED', reason: 'C-before-B', mutations: 0, action: 'STOP' };
    if (cb.order === 0) return { state: 'UPDATE', reason: 'resume-existing-B', mutations: 0, action: 'RESUME' };
    return { state: 'UPDATE', reason: 'advance-existing-B-to-C', mutations: 2, action: 'ADVANCE' };
  }
  if (ca.order === 0) return { state: 'NOOP', reason: 'already-adopted-no-pending-B', mutations: 0, action: 'NONE' };
  return { state: 'UPDATE', reason: 'newer-proven-C', mutations: 2, action: 'CREATE' };
}

export function decideCandidate(definition, candidate) {
  return decideThreeVersion(definition, candidate, null);
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
  if (observed.marker !== prMarker(name)) return noMutation('STOP', 'PRKey-marker-mismatch');
  if (observed.branch !== `bot/cli-release-${name}`) return noMutation('STOP', 'fixed-branch-mismatch');
  if (observed.headActor !== observed.expectedPrincipal) return noMutation('STOP', 'foreign-head-actor');
  if (observed.head !== observed.expectedHead) return noMutation('STOP', 'head-lease-mismatch');
  if (observed.preimage !== observed.expectedPreimage) return noMutation('STOP', 'target-preimage-mismatch');
  if ((observed.humanCommits ?? 0) !== 0) return noMutation('STOP', 'human-or-foreign-commit');
  if ((observed.changedPaths ?? []).some((path) => path !== REGISTRY_PATH)) return noMutation('STOP', 'unexpected-path');
  const allowedPointers = new Set([`/${name}/pin/version`, `/${name}/pin/contentHash`]);
  if ((observed.changedPointers ?? []).some((pointer) => !allowedPointers.has(pointer))) return noMutation('STOP', 'unexpected-json-pointer');
  if (observed.effect === 'CONFIRMED_DONE') return noMutation('JUDGE_EXISTING', 'effect-already-exists');
  if (observed.effect === 'CONFIRMED_NOT_DONE') return { state: 'EXECUTE_PENDING', reason: 'authorized-pending-effect', effectResend: 0, mutations: 1, prKey: prKey(name) };
  return noMutation('STOP', observed.effect === 'PARTIAL_OR_FAILED' ? 'partial-or-failed' : 'still-unknown');
}

async function responseBytes(response, label) {
  if (!response.ok) fail(`${label}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

async function responseJson(response, label) {
  const bytes = await responseBytes(response, label);
  try { return JSON.parse(bytes.toString('utf8')); } catch { fail(`${label}: invalid JSON`); }
}

async function responseText(response, label) {
  return (await responseBytes(response, label)).toString('utf8').trim();
}

async function defaultRun(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: { ...process.env, ...options.env }, stdio: ['ignore', 'pipe', 'pipe'] });
    const out = [];
    const err = [];
    child.stdout.on('data', (chunk) => out.push(chunk));
    child.stderr.on('data', (chunk) => err.push(chunk));
    const timer = setTimeout(() => child.kill('SIGKILL'), options.timeoutMs ?? 120_000);
    child.on('error', reject);
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') });
    });
  });
}

async function withTemp(prefix, fn) {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  try { return await fn(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

async function verifySigstore({ name, version, bytes, bundle, proof, runImpl }) {
  const identity = `${proof.certificateIdentityPrefix}${version}`;
  return withTemp('release-sigstore-', async (directory) => {
    const artifact = join(directory, 'artifact');
    const bundlePath = join(directory, 'artifact.sigstore');
    await writeFile(artifact, bytes, { mode: 0o600 });
    await writeFile(bundlePath, bundle, { mode: 0o600 });
    const result = await runImpl(process.env.RELEASE_WATCH_COSIGN ?? 'cosign', [
      'verify-blob', '--offline', '--bundle', bundlePath,
      '--certificate-identity', identity,
      '--certificate-oidc-issuer', proof.certificateOidcIssuer,
      artifact,
    ]);
    if (result.code !== 0) fail(`${name}: Sigstore verification failed: ${result.stderr.slice(0, 300)}`);
    return { kind: proof.kind, identity, issuer: proof.certificateOidcIssuer, rekor: true };
  });
}

async function verifyGpgManifest({ name, manifest, signature, key, proof, runImpl }) {
  return withTemp('release-gpg-', async (directory) => {
    const manifestPath = join(directory, proof.manifestName);
    const signaturePath = join(directory, proof.signatureName);
    const keyPath = join(directory, 'release-key.asc');
    await writeFile(manifestPath, manifest, { mode: 0o600 });
    await writeFile(signaturePath, signature, { mode: 0o600 });
    await writeFile(keyPath, key, { mode: 0o600 });
    const gpg = process.env.RELEASE_WATCH_GPG ?? 'gpg';
    const common = ['--batch', '--no-tty', '--homedir', directory];
    const imported = await runImpl(gpg, [...common, '--import', keyPath]);
    if (imported.code !== 0) fail(`${name}: GPG key import failed: ${imported.stderr.slice(0, 300)}`);
    const listed = await runImpl(gpg, [...common, '--with-colons', '--fingerprint']);
    const fingerprints = listed.stdout.split('\n').filter((line) => line.startsWith('fpr:')).map((line) => line.split(':')[9]);
    if (!fingerprints.includes(proof.keyFingerprint)) fail(`${name}: signing key fingerprint mismatch`);
    const verified = await runImpl(gpg, [...common, '--status-fd', '1', '--verify', signaturePath, manifestPath]);
    const valid = verified.stdout.split('\n').some((line) => line.startsWith('[GNUPG:] VALIDSIG ') && line.split(' ')[2] === proof.keyFingerprint);
    if (verified.code !== 0 || !valid) fail(`${name}: manifest signature failed: ${verified.stderr.slice(0, 300)}`);
    return { kind: proof.kind, keyFingerprint: proof.keyFingerprint };
  });
}

export async function resolveCandidate(name, definition, options = {}) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const runImpl = options.runImpl ?? defaultRun;
  const { contract } = definition;
  if (contract.sourceKind === 'github-release') {
    const release = await responseJson(await fetchImpl(`https://api.github.com/repos/${contract.officialSource}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
    }), `${name}: release`);
    if (release.draft || release.prerelease) fail(`${name}: latest release is not stable`);
    if (typeof release.tag_name !== 'string' || !release.tag_name.startsWith('rust-v')) fail(`${name}: unexpected release tag`);
    const version = release.tag_name.slice('rust-v'.length);
    if (!parseVersion(version)) fail(`${name}: non-semver release tag`);
    const asset = (release.assets ?? []).find((item) => item.name === contract.assetSelector);
    const proofAsset = (release.assets ?? []).find((item) => item.name === `${contract.assetSelector}${contract.proof.assetSuffix}`);
    if (!asset || !proofAsset) fail(`${name}: selected asset or proof is absent`);
    const officialHash = typeof asset.digest === 'string' && asset.digest.startsWith('sha256:') ? asset.digest.slice(7) : null;
    if (!/^[0-9a-f]{64}$/.test(officialHash ?? '')) fail(`${name}: official selected asset digest is absent`);
    const [bytes, bundle] = await Promise.all([
      responseBytes(await fetchImpl(asset.browser_download_url), `${name}: selected bytes`),
      responseBytes(await fetchImpl(proofAsset.browser_download_url), `${name}: Sigstore bundle`),
    ]);
    const contentHash = sha256(bytes);
    if (contentHash !== officialHash) fail(`${name}: selected bytes differ from official digest`);
    const proof = await verifySigstore({ name, version, bytes, bundle, proof: contract.proof, runImpl });
    return { version, contentHash, proof: true, proofReceipt: proof, sourceUrl: asset.browser_download_url, selectedBytes: bytes.length };
  }
  if (contract.sourceKind === 'claude-manifest') {
    const stableRaw = await responseText(await fetchImpl(`${contract.officialSource}/stable`), `${name}: stable`);
    let version = stableRaw;
    try { const parsed = JSON.parse(stableRaw); version = parsed.version ?? parsed.latest ?? stableRaw; } catch { /* plain version */ }
    if (!parseVersion(version)) fail(`${name}: stable endpoint returned an invalid version`);
    const base = `${contract.officialSource}/${version}`;
    const [manifestBytes, signature, key, selectedBytes] = await Promise.all([
      responseBytes(await fetchImpl(`${base}/${contract.proof.manifestName}`), `${name}: manifest`),
      responseBytes(await fetchImpl(`${base}/${contract.proof.signatureName}`), `${name}: manifest signature`),
      responseBytes(await fetchImpl(contract.proof.keyUrl), `${name}: signing key`),
      responseBytes(await fetchImpl(`${base}/${contract.platform}/${contract.assetSelector}`), `${name}: selected bytes`),
    ]);
    const proof = await verifyGpgManifest({ name, manifest: manifestBytes, signature, key, proof: contract.proof, runImpl });
    let manifest;
    try { manifest = JSON.parse(manifestBytes.toString('utf8')); } catch { fail(`${name}: signed manifest is invalid JSON`); }
    if (manifest.version !== version) fail(`${name}: signed manifest version differs from stable channel`);
    const platform = manifest.platforms?.[contract.platform];
    if (!platform) fail(`${name}: signed manifest platform is absent`);
    const authenticatedHash = platform.checksum ?? platform.sha256;
    if (!/^[0-9a-f]{64}$/.test(authenticatedHash ?? '')) fail(`${name}: signed manifest sha256 is absent`);
    const contentHash = sha256(selectedBytes);
    if (contentHash !== authenticatedHash) fail(`${name}: selected bytes differ from signed manifest`);
    return { version, contentHash, proof: true, proofReceipt: proof, sourceUrl: `${base}/${contract.platform}/${contract.assetSelector}`, selectedBytes: selectedBytes.length };
  }
  fail(`${name}: no resolver for ${contract.sourceKind}`);
}

function githubHeaders(token) {
  return { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28' };
}

export function githubClient(repository, token, fetchImpl = fetch) {
  return async (method, path, body) => {
    const response = await fetchImpl(`https://api.github.com/repos/${repository}${path}`, {
      method, headers: githubHeaders(token), body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (response.status === 404 && method === 'GET') return null;
    if (!response.ok) fail(`GitHub ${method} ${path}: HTTP ${response.status} ${(await response.text()).slice(0, 300)}`);
    if (response.status === 204) return null;
    const value = await response.json();
    if (Array.isArray(value)) {
      Object.defineProperty(value, PAGE_META, {
        enumerable: false,
        value: { link: response.headers.get('link'), path },
      });
    }
    return value;
  };
}

export async function reconcileEffect({ observe, mutate }) {
  const before = await observe();
  if (before === 'CONFIRMED_DONE') return { state: before, sends: 0 };
  if (before !== 'CONFIRMED_NOT_DONE') return { state: before, sends: 0 };
  let mutationError = null;
  try { await mutate(); } catch (error) { mutationError = error; }
  let after;
  try { after = await observe(); } catch { after = 'STILL_UNKNOWN'; }
  if (after === 'CONFIRMED_DONE') return { state: after, sends: 1, mutationError: mutationError?.message ?? null };
  if (mutationError && after === 'CONFIRMED_NOT_DONE') return { state: 'PARTIAL_OR_FAILED', sends: 1, mutationError: mutationError.message };
  return { state: after, sends: 1, mutationError: mutationError?.message ?? null };
}

function changedPointers(base, next, name) {
  const pointers = [];
  if (base[name].pin.version !== next[name].pin.version) pointers.push(`/${name}/pin/version`);
  if (base[name].pin.contentHash !== next[name].pin.contentHash) pointers.push(`/${name}/pin/contentHash`);
  const normalized = structuredClone(base);
  normalized[name].pin = structuredClone(next[name].pin);
  if (JSON.stringify(normalized) !== JSON.stringify(next)) pointers.push('/unexpected');
  return pointers;
}

async function readRegistryAt(api, ref) {
  const file = await api('GET', `/contents/${REGISTRY_PATH}?ref=${encodeURIComponent(ref)}`);
  if (!file?.content) fail(`registry is absent at ${ref}`);
  return validateRegistry(JSON.parse(Buffer.from(file.content, 'base64').toString('utf8')));
}

function nextPageFromLink(link) {
  if (link === null || link === undefined || link === '') return null;
  if (typeof link !== 'string') fail('GitHub Link header is invalid');
  const next = link.split(',').map((item) => item.trim()).find((item) => /;\s*rel="next"$/.test(item));
  if (!next) return null;
  const match = /^<([^>]+)>;\s*rel="next"$/.exec(next);
  if (!match) fail('GitHub next Link header is malformed');
  const page = Number(new URL(match[1]).searchParams.get('page'));
  if (!Number.isSafeInteger(page) || page < 2) fail('GitHub next page is invalid');
  return page;
}

export async function listAll(api, path, { maxPages = MAX_API_PAGES, maxItems = maxPages * PAGE_SIZE } = {}) {
  if (!Number.isSafeInteger(maxPages) || maxPages < 1) fail('maxPages must be a positive integer');
  if (!Number.isSafeInteger(maxItems) || maxItems < 1 || maxItems > maxPages * PAGE_SIZE) fail('maxItems must fit the declared page bound');
  const url = new URL(path, 'https://api.github.invalid');
  if (url.searchParams.has('page') || url.searchParams.has('per_page')) fail(`collection path already controls pagination: ${path}`);
  const values = [];
  for (let page = 1; page <= maxPages; page += 1) {
    url.searchParams.set('per_page', String(PAGE_SIZE));
    url.searchParams.set('page', String(page));
    const pagePath = `${url.pathname}${url.search}`;
    const pageValues = await api('GET', pagePath);
    if (!Array.isArray(pageValues)) fail(`GitHub collection is not an array: ${path}`);
    if (pageValues.length > PAGE_SIZE) fail(`GitHub collection page exceeds ${PAGE_SIZE}: ${path}`);
    const linkNext = nextPageFromLink(pageValues[PAGE_META]?.link);
    if (linkNext !== null && linkNext !== page + 1) fail(`GitHub pagination skipped a page: ${path}`);
    if (linkNext !== null && pageValues.length !== PAGE_SIZE) fail(`GitHub pagination count/header mismatch: ${path}`);
    values.push(...pageValues);
    if (values.length > maxItems) fail(`GitHub collection exceeds declared item limit ${maxItems}: ${path}`);
    if (linkNext !== null && values.length >= maxItems) fail(`GitHub collection continues beyond declared item limit ${maxItems}: ${path}`);
    if (linkNext === null && pageValues.length < PAGE_SIZE) return values;
    if (linkNext === null && pageValues[PAGE_META] && pageValues.length === PAGE_SIZE) return values;
  }
  fail(`GitHub collection exceeds declared limit ${maxPages * PAGE_SIZE}: ${path}`);
}

function assertPrShape({ pr, repository, baseBranch, branch, name, expectedPrincipal }) {
  if (pr.user?.login !== expectedPrincipal) fail(`${name}: foreign PR author`);
  if (pr.base?.ref !== baseBranch || pr.head?.ref !== branch || pr.head?.repo?.full_name !== repository) {
    fail(`${name}: PR target/head differs`);
  }
  if (!String(pr.body ?? '').includes(prMarker(name))) fail(`${name}: PRKey marker differs`);
}

async function inspectBotPrHistory({ api, pr, refSha, registry, name, expectedPrincipal }) {
  if (!/^[0-9a-f]{40}$/.test(pr.base?.sha ?? '')) fail(`${name}: PR base preimage is absent`);
  const commits = await listAll(api, `/pulls/${pr.number}/commits`, COLLECTION_LIMITS.commits);
  if (commits.length === 0) fail(`${name}: bot PR has no commits`);
  const foreignCommits = commits.filter((commit) =>
    (commit.author?.login ?? commit.committer?.login) !== expectedPrincipal);
  if (foreignCommits.length !== 0) fail(`${name}: human or foreign commit`);
  const headCommit = await api('GET', `/commits/${refSha}`);
  const actor = headCommit?.author?.login ?? headCommit?.committer?.login;
  if (actor !== expectedPrincipal) fail(`${name}: foreign head actor`);
  const files = await listAll(api, `/pulls/${pr.number}/files`, COLLECTION_LIMITS.files);
  const changedPaths = files.map((file) => file.filename);
  if (changedPaths.length !== 1 || changedPaths[0] !== REGISTRY_PATH) fail(`${name}: unexpected changed path`);
  const branchRegistry = await readRegistryAt(api, refSha);
  const baseRegistry = await readRegistryAt(api, pr.base.sha);
  const pointers = changedPointers(baseRegistry, branchRegistry, name);
  if (pointers.length !== 2 || pointers.some((pointer) => ![`/${name}/pin/version`, `/${name}/pin/contentHash`].includes(pointer))) {
    fail(`${name}: unexpected changed pointer`);
  }
  if (JSON.stringify(branchRegistry[name].contract) !== JSON.stringify(registry[name].contract)) {
    fail(`${name}: retained contract differs from canonical A`);
  }
  return { actor, changedPaths, branchRegistry, pointers };
}

export async function inspectExistingBotPr({ api, repository, baseBranch, baseSha, registry, name, expectedPrincipal = BOT_LOGIN }) {
  const [owner] = repository.split('/');
  const branch = `bot/cli-release-${name}`;
  const openPrs = await listAll(api, `/pulls?state=open&base=${encodeURIComponent(baseBranch)}&head=${encodeURIComponent(`${owner}:${branch}`)}`, COLLECTION_LIMITS.openPrs);
  if (openPrs.length > 1) fail(`${name}: more than one bot PR exists`);
  const ref = await api('GET', `/git/ref/heads/${encodeURIComponent(branch)}`);

  if (openPrs.length === 1) {
    const pr = openPrs[0];
    assertPrShape({ pr, repository, baseBranch, branch, name, expectedPrincipal });
    if (!ref?.object?.sha || ref.object.sha !== pr.head.sha) fail(`${name}: head lease differs`);
    const history = await inspectBotPrHistory({ api, pr, refSha: ref.object.sha, registry, name, expectedPrincipal });
    const compare = await api('GET', `/compare/${encodeURIComponent(baseSha)}...${encodeURIComponent(ref.object.sha)}`);
    if (compare?.merge_base_commit?.sha !== baseSha) fail(`${name}: target preimage differs`);
    return {
      exists: true, retained: false, branch, pr, head: ref.object.sha,
      headActor: history.actor, expectedPrincipal,
      pendingPin: structuredClone(history.branchRegistry[name].pin),
      pendingRegistry: history.branchRegistry,
      observed: {
        effect: 'CONFIRMED_DONE', principal: pr.user.login, expectedPrincipal,
        marker: prMarker(name), branch, headActor: history.actor,
        head: ref.object.sha, expectedHead: ref.object.sha,
        preimage: compare.merge_base_commit.sha, expectedPreimage: baseSha,
        humanCommits: 0, changedPaths: history.changedPaths, changedPointers: history.pointers,
      },
    };
  }

  if (ref === null) {
    return { exists: false, retained: false, branch, pendingPin: null, effect: 'CONFIRMED_NOT_DONE' };
  }
  if (!ref?.object?.sha) fail(`${name}: retained branch ref is malformed`);
  const retainedHead = ref.object.sha;
  const closedPrs = await listAll(api, `/pulls?state=closed&base=${encodeURIComponent(baseBranch)}&head=${encodeURIComponent(`${owner}:${branch}`)}&sort=updated&direction=desc`, COLLECTION_LIMITS.closedPrs);
  const matching = closedPrs.filter((pr) => pr.head?.sha === retainedHead);
  if (matching.length !== 1) fail(`${name}: retained branch is orphaned or ambiguous`);
  const pr = await api('GET', `/pulls/${matching[0].number}`);
  if (!pr?.merged_at) fail(`${name}: retained branch PR was not merged`);
  assertPrShape({ pr, repository, baseBranch, branch, name, expectedPrincipal });
  if (pr.head?.sha !== retainedHead) fail(`${name}: retained branch head differs from merged PR`);
  const history = await inspectBotPrHistory({ api, pr, refSha: retainedHead, registry, name, expectedPrincipal });
  const admittedMergeSha = pr.merge_commit_sha;
  if (!/^[0-9a-f]{40}$/.test(admittedMergeSha ?? '')) fail(`${name}: merged PR admission commit is absent`);
  const ancestry = await api('GET', `/compare/${encodeURIComponent(admittedMergeSha)}...${encodeURIComponent(baseSha)}`);
  if (ancestry?.merge_base_commit?.sha !== admittedMergeSha) fail(`${name}: merged PR result is not an ancestor of canonical A`);
  const canonicalVsRetained = comparePin(registry[name].pin, history.branchRegistry[name].pin);
  if (canonicalVsRetained?.state === 'RED' || canonicalVsRetained?.order < 0) {
    fail(`${name}: retained branch pin is not admitted by canonical A`);
  }
  return {
    exists: false, retained: true, branch, retainedHead, admittedMergeSha,
    pendingPin: null, effect: 'CONFIRMED_NOT_DONE',
  };
}

export async function bindCanonicalInput({ api, baseBranch = BASE_BRANCH, checkoutSha, localRegistry }) {
  if (!/^[0-9a-f]{40}$/.test(checkoutSha ?? '')) fail('checked-out source SHA is absent');
  const baseRef = await api('GET', `/git/ref/heads/${encodeURIComponent(baseBranch)}`);
  const baseSha = baseRef?.object?.sha;
  if (!baseSha) fail('canonical base ref is absent');
  if (baseSha !== checkoutSha) fail('canonical A advanced beyond checked-out source');
  const canonicalRegistry = await readRegistryAt(api, baseSha);
  if (JSON.stringify(canonicalRegistry) !== JSON.stringify(localRegistry)) {
    fail('checked-out registry differs from canonical A');
  }
  return { baseSha, registry: canonicalRegistry };
}

async function assertCanonicalLease({ api, baseBranch = BASE_BRANCH, baseSha }) {
  const current = await api('GET', `/git/ref/heads/${encodeURIComponent(baseBranch)}`);
  if (current?.object?.sha !== baseSha) fail('canonical A moved before mutation');
}

function gitObjectSha(type, content) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
  return createHash('sha1').update(Buffer.from(`${type} ${bytes.length}\0`)).update(bytes).digest('hex');
}

function gitTreeSha(entries) {
  const normalized = entries.map((entry) => {
    if (!/^[0-9a-f]{40}$/.test(entry.sha ?? '')) fail(`invalid tree entry sha: ${entry.path ?? ''}`);
    if (typeof entry.path !== 'string' || entry.path.length === 0 || entry.path.includes('/')) fail('tree entry path must be one element');
    if (!/^[0-7]{6}$/.test(entry.mode ?? '')) fail(`invalid tree entry mode: ${entry.path}`);
    const mode = entry.mode.replace(/^0+(?=\d)/, '');
    return { ...entry, mode, sortKey: Buffer.from(`${entry.path}${entry.type === 'tree' ? '/' : ''}`) };
  }).sort((left, right) => Buffer.compare(left.sortKey, right.sortKey));
  const chunks = [];
  for (const entry of normalized) {
    chunks.push(Buffer.from(`${entry.mode} ${entry.path}\0`));
    chunks.push(Buffer.from(entry.sha, 'hex'));
  }
  return gitObjectSha('tree', Buffer.concat(chunks));
}

async function expectedTreeWithReplacement(api, treeSha, parts, replacement) {
  const tree = await api('GET', `/git/trees/${treeSha}`);
  if (!tree || tree.truncated === true || !Array.isArray(tree.tree)) fail(`base tree cannot be read completely: ${treeSha}`);
  const [part, ...rest] = parts;
  if (!part || part === '.' || part === '..' || part.includes('/')) fail('registry path is not a safe tree path');
  const entries = tree.tree.map((entry) => ({ path: entry.path, mode: entry.mode, type: entry.type, sha: entry.sha }));
  const index = entries.findIndex((entry) => entry.path === part);
  if (index < 0) fail(`base tree path is absent: ${part}`);
  if (rest.length === 0) {
    entries[index] = { path: part, mode: replacement.mode, type: replacement.type, sha: replacement.sha };
  } else {
    if (entries[index].type !== 'tree') fail(`base tree path is not a tree: ${part}`);
    const childSha = await expectedTreeWithReplacement(api, entries[index].sha, rest, replacement);
    entries[index] = { ...entries[index], sha: childSha };
  }
  return gitTreeSha(entries);
}

function normalizedGitDate(value) {
  const milliseconds = Date.parse(value ?? '');
  if (!Number.isFinite(milliseconds)) fail('commit receipt date is absent');
  return new Date(milliseconds).toISOString();
}

function gitCommitSha({ tree, parents, message, author, committer }) {
  const identity = (value) => {
    const seconds = Math.floor(Date.parse(value.date) / 1000);
    return `${value.name} <${value.email}> ${seconds} +0000`;
  };
  const content = [
    `tree ${tree}`,
    ...parents.map((parent) => `parent ${parent}`),
    `author ${identity(author)}`,
    `committer ${identity(committer)}`,
    '',
    message,
  ].join('\n');
  return gitObjectSha('commit', content);
}

async function requireObjectReceipt(label, effect) {
  const result = await reconcileEffect(effect);
  if (result.state !== 'CONFIRMED_DONE') fail(`${label}: ${result.state}`);
  return result;
}

export async function createImmutableCommit({ api, parentShas, treeBaseSha, registry, message }) {
  if (!Array.isArray(parentShas) || parentShas.length < 1 || parentShas.some((sha) => !/^[0-9a-f]{40}$/.test(sha))) {
    fail('commit parents are invalid');
  }
  if (!/^[0-9a-f]{40}$/.test(treeBaseSha ?? '')) fail('tree base commit is invalid');
  const baseCommit = await api('GET', `/git/commits/${treeBaseSha}`);
  if (!baseCommit?.tree?.sha) fail('tree base commit/tree absent');

  const registryBytes = Buffer.from(`${JSON.stringify(registry, null, 2)}\n`);
  const blobSha = gitObjectSha('blob', registryBytes);
  const blobReceipt = await requireObjectReceipt('registry blob', {
    observe: async () => {
      const blob = await api('GET', `/git/blobs/${blobSha}`);
      if (blob === null) return 'CONFIRMED_NOT_DONE';
      if (blob?.encoding !== 'base64' || typeof blob.content !== 'string') return 'PARTIAL_OR_FAILED';
      const actual = Buffer.from(blob.content.replace(/\n/g, ''), 'base64');
      return gitObjectSha('blob', actual) === blobSha && actual.equals(registryBytes)
        ? 'CONFIRMED_DONE' : 'PARTIAL_OR_FAILED';
    },
    mutate: async () => {
      const created = await api('POST', '/git/blobs', { content: registryBytes.toString('base64'), encoding: 'base64' });
      if (created?.sha !== blobSha) fail('registry blob response sha differs');
    },
  });

  const treeSha = await expectedTreeWithReplacement(
    api, baseCommit.tree.sha, REGISTRY_PATH.split('/'),
    { mode: '100644', type: 'blob', sha: blobSha },
  );
  const treeReceipt = await requireObjectReceipt('registry tree', {
    observe: async () => {
      const tree = await api('GET', `/git/trees/${treeSha}`);
      return tree === null ? 'CONFIRMED_NOT_DONE'
        : tree?.sha === treeSha && tree.truncated !== true ? 'CONFIRMED_DONE' : 'PARTIAL_OR_FAILED';
    },
    mutate: async () => {
      const created = await api('POST', '/git/trees', {
        base_tree: baseCommit.tree.sha,
        tree: [{ path: REGISTRY_PATH, mode: '100644', type: 'blob', sha: blobSha }],
      });
      if (created?.sha !== treeSha) fail('registry tree response sha differs');
    },
  });

  const date = normalizedGitDate(baseCommit.committer?.date ?? baseCommit.author?.date);
  const normalizedMessage = message.endsWith('\n') ? message : `${message}\n`;
  const author = { ...BOT_GIT_IDENTITY, date };
  const committer = { ...BOT_GIT_IDENTITY, date };
  const commitBody = { message: normalizedMessage, tree: treeSha, parents: parentShas, author, committer };
  const commitSha = gitCommitSha(commitBody);
  const commitReceipt = await requireObjectReceipt('candidate commit', {
    observe: async () => {
      const commit = await api('GET', `/git/commits/${commitSha}`);
      if (commit === null) return 'CONFIRMED_NOT_DONE';
      const parents = (commit.parents ?? []).map((parent) => parent.sha);
      const exact = commit?.sha === commitSha && commit.tree?.sha === treeSha
        && JSON.stringify(parents) === JSON.stringify(parentShas)
        && commit.message === normalizedMessage
        && commit.author?.name === author.name && commit.author?.email === author.email
        && normalizedGitDate(commit.author?.date) === date
        && commit.committer?.name === committer.name && commit.committer?.email === committer.email
        && normalizedGitDate(commit.committer?.date) === date;
      return exact ? 'CONFIRMED_DONE' : 'PARTIAL_OR_FAILED';
    },
    mutate: async () => {
      const created = await api('POST', '/git/commits', commitBody);
      if (created?.sha !== commitSha) fail('candidate commit response sha differs');
    },
  });

  return { sha: commitSha, receipts: { blob: blobReceipt, tree: treeReceipt, commit: commitReceipt } };
}

export async function reconcileRef({ api, branch, expectedOldSha, newSha, create }) {
  const readPath = `/git/ref/heads/${encodeURIComponent(branch)}`;
  const writePath = `/git/refs/heads/${encodeURIComponent(branch)}`;
  if (!create) {
    if (!/^[0-9a-f]{40}$/.test(expectedOldSha ?? '')) fail('ref update lease is absent');
    const compare = await api('GET', `/compare/${encodeURIComponent(expectedOldSha)}...${encodeURIComponent(newSha)}`);
    if (compare?.merge_base_commit?.sha !== expectedOldSha) fail('ref update is not a normal fast-forward');
  }
  const observe = async () => {
    const ref = await api('GET', readPath);
    if (ref?.object?.sha === newSha) return 'CONFIRMED_DONE';
    if (create && ref === null) return 'CONFIRMED_NOT_DONE';
    if (!create && ref?.object?.sha === expectedOldSha) return 'CONFIRMED_NOT_DONE';
    return ref ? 'PARTIAL_OR_FAILED' : 'STILL_UNKNOWN';
  };
  return reconcileEffect({ observe, mutate: () => create
    ? api('POST', '/git/refs', { ref: `refs/heads/${branch}`, sha: newSha })
    : api('PATCH', writePath, { sha: newSha, force: false }) });
}

export async function reconcilePrCreate({ api, repository, baseBranch, branch, name, title, body }) {
  const [owner] = repository.split('/');
  const observePr = async () => {
    const prs = await listAll(api, `/pulls?state=open&base=${encodeURIComponent(baseBranch)}&head=${encodeURIComponent(`${owner}:${branch}`)}`, COLLECTION_LIMITS.openPrs);
    if (prs.length === 0) return 'CONFIRMED_NOT_DONE';
    if (prs.length !== 1) return 'PARTIAL_OR_FAILED';
    return prs[0].user?.login === BOT_LOGIN && String(prs[0].body ?? '').includes(prMarker(name)) ? 'CONFIRMED_DONE' : 'PARTIAL_OR_FAILED';
  };
  return reconcileEffect({ observe: observePr, mutate: () => api('POST', '/pulls', { title, head: branch, base: baseBranch, body, draft: true }) });
}

export async function maintainOne({
  repository, token, baseBranch = BASE_BRANCH, baseSha, registry, name, candidate,
  fetchImpl = fetch, api: apiOverride = null,
}) {
  const api = apiOverride ?? githubClient(repository, token, fetchImpl);
  const existing = await inspectExistingBotPr({ api, repository, baseBranch, baseSha, registry, name });
  const decision = decideThreeVersion(registry[name], candidate, existing.pendingPin);
  if (decision.state === 'RED' || decision.state === 'NOOP') return { name, decision, effects: 0 };
  if (decision.action === 'RESUME') return { name, decision, effects: 0, pr: existing.pr?.html_url ?? null };
  const next = applyPin(registry, name, candidate);
  await assertCanonicalLease({ api, baseBranch, baseSha });
  const parentShas = existing.exists ? [existing.head]
    : existing.retained ? [existing.retainedHead, baseSha] : [baseSha];
  const treeBaseSha = existing.exists ? existing.head : baseSha;
  const commit = await createImmutableCommit({
    api, parentShas, treeBaseSha, registry: next,
    message: `chore: update ${name} to ${candidate.version}

${prKey(name)}`,
  });
  const createRef = !existing.exists && !existing.retained;
  const expectedOldSha = existing.exists ? existing.head : existing.retainedHead ?? null;
  const refEffect = await reconcileRef({ api, branch: existing.branch, expectedOldSha, newSha: commit.sha, create: createRef });
  if (refEffect.state !== 'CONFIRMED_DONE') return { name, decision, refEffect, effects: 1, state: 'STOP' };
  let prEffect = { state: 'CONFIRMED_DONE', sends: 0 };
  if (!existing.exists) {
    const title = `chore: update ${name} to ${candidate.version}`;
    const body = `${prMarker(name)}

Official stable release verified cryptographically.

- CLI: \`${name}\`
- version: \`${candidate.version}\`
- sha256: \`${candidate.contentHash}\`
- manual approval and CI are still required.`;
    prEffect = await reconcilePrCreate({ api, repository, baseBranch, branch: existing.branch, name, title, body });
  }
  return { name, decision, refEffect, prEffect, effects: refEffect.sends + prEffect.sends, state: prEffect.state === 'CONFIRMED_DONE' ? 'DONE' : 'STOP' };
}

async function loadRegistry(path) {
  return validateRegistry(JSON.parse(await readFile(path, 'utf8')));
}

async function resolveAll(registry, options = {}) {
  const result = {};
  for (const name of Object.keys(registry).sort()) {
    try {
      const candidate = await resolveCandidate(name, registry[name], options);
      result[name] = { candidate, decision: decideCandidate(registry[name], candidate) };
    } catch (error) {
      result[name] = { candidate: null, decision: { state: 'RED', reason: error.message, mutations: 0, action: 'STOP' } };
    }
  }
  return result;
}

async function commandMain(argv) {
  const [command, registryPath = 'hosts/profile/releases.json'] = argv;
  const registry = await loadRegistry(registryPath);
  if (command === 'validate') {
    process.stdout.write(`${JSON.stringify(releaseVersions(registry))}\n`);
    return;
  }
  if (command === 'resolve') {
    const result = await resolveAll(registry);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (Object.values(result).some((item) => item.decision.state === 'RED')) process.exitCode = 1;
    return;
  }
  if (command === 'propose') {
    const repository = process.env.GITHUB_REPOSITORY;
    const token = process.env.GITHUB_TOKEN;
    if (!repository || !token) fail('GITHUB_REPOSITORY and GITHUB_TOKEN are required');
    const api = githubClient(repository, token);
    const checkoutSha = process.env.RELEASE_WATCH_CHECKOUT_SHA;
    const canonical = await bindCanonicalInput({ api, checkoutSha, localRegistry: registry });
    const resolved = await resolveAll(canonical.registry);
    const output = [];
    for (const name of Object.keys(canonical.registry).sort()) {
      const item = resolved[name];
      if (item.decision.state === 'RED') { output.push({ name, ...item }); continue; }
      output.push(await maintainOne({
        repository, token, baseSha: canonical.baseSha, registry: canonical.registry,
        name, candidate: item.candidate, api,
      }));
    }
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
    if (output.some((item) => item.decision?.state === 'RED' || item.state === 'STOP')) process.exitCode = 1;
    return;
  }
  fail(`usage: watch.mjs validate|resolve|propose [registry.json]`);
}

const invoked = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invoked) commandMain(process.argv.slice(2)).catch((error) => { console.error(`RED ${error.message}`); process.exitCode = 1; });
