import assert from 'node:assert/strict';
import test from 'node:test';
import {
  applyPin, compareVersions, decideCandidate, planApiEffect, prKey,
  releaseVersions, validateRegistry,
} from './watch.mjs';

const hash = (char) => char.repeat(64);
const contract = (overrides = {}) => ({
  sourceKind: 'github-release',
  officialSource: 'example/tool',
  channel: 'stable',
  versionScheme: 'semver',
  platform: 'x86_64-unknown-linux-musl',
  assetSelector: 'tool.tar.gz',
  verifyKind: 'github-asset-digest',
  packageShape: 'codex-musl-tar',
  ...overrides,
});
const definition = (version = '1.2.3', contentHash = hash('a'), overrides = {}) => ({
  contract: contract(overrides), pin: { version, contentHash },
});
const registry = () => ({
  alpha: definition(),
  beta: definition('2.0.0', hash('b'), {
    sourceKind: 'claude-manifest',
    officialSource: 'https://downloads.claude.ai/claude-code-releases',
    platform: 'linux-x64',
    assetSelector: 'claude',
    verifyKind: 'manifest-sha256',
    packageShape: 'single-glibc-executable',
  }),
  gamma: definition('3.0.0', hash('c')),
});
const candidate = (version, contentHash = hash('d'), proof = true) => ({ version, contentHash, proof });
const observed = (overrides = {}) => ({
  effect: 'CONFIRMED_NOT_DONE',
  principal: 'github-actions[bot]', expectedPrincipal: 'github-actions[bot]',
  head: hash('1').slice(0, 40), expectedHead: hash('1').slice(0, 40),
  preimage: hash('2'), expectedPreimage: hash('2'),
  humanCommits: 0,
  changedPaths: ['hosts/profile/releases.json'],
  changedPointers: ['/alpha/pin/version', '/alpha/pin/contentHash'],
  ...overrides,
});

function unchanged(value, action) {
  const before = JSON.stringify(value);
  const result = action();
  assert.equal(JSON.stringify(value), before);
  return result;
}

test('V0 strict D_i schema and third same-kind registration', () => {
  const data = registry();
  assert.equal(validateRegistry(data), data);
  assert.deepEqual(releaseVersions(data), { alpha: '1.2.3', beta: '2.0.0', gamma: '3.0.0' });
  assert.equal(data.alpha.contract.sourceKind, data.gamma.contract.sourceKind);
  assert.equal(data.alpha.contract.verifyKind, data.gamma.contract.verifyKind);
  assert.throws(() => validateRegistry({ alpha: { ...data.alpha, extra: 'code' } }), /keys differ/);
  assert.throws(() => validateRegistry({ alpha: definition('1.2.3;throw') }), /invalid stable semver/);
});

test('V1 versions are ordered only when comparable stable semver', () => {
  assert.equal(compareVersions('1.2.3', '1.2.3'), 0);
  assert.equal(compareVersions('1.2.4', '1.2.3'), 1);
  assert.equal(compareVersions('1.2.2', '1.2.3'), -1);
  assert.equal(compareVersions('latest', '1.2.3'), null);
});

test('V1 NOOP and newer UPDATE', () => {
  const current = definition();
  assert.deepEqual(decideCandidate(current, candidate('1.2.3', hash('a'))), {
    state: 'NOOP', reason: 'already-adopted', mutations: 0,
  });
  assert.deepEqual(decideCandidate(current, candidate('1.2.4')), {
    state: 'UPDATE', reason: 'newer-proven-release', mutations: 2,
  });
});

test('V1 downgrade, incomparable, hash drift, resolver/proof failure and A/B reversal are RED', () => {
  const current = definition('2.0.0', hash('a'));
  for (const [item, reason] of [
    [candidate('1.9.9'), 'downgrade'],
    [candidate('latest'), 'incomparable-version'],
    [candidate('2.0.0', hash('b')), 'same-version-hash-drift'],
    [candidate('2.0.1', hash('b'), false), 'proof-failed'],
    [candidate('1.2.4'), 'downgrade'],
  ]) assert.equal(decideCandidate(current, item).reason, reason);
});

test('V1 pin update changes exactly two admitted pointers and never K_i', () => {
  const data = registry();
  const contractBefore = JSON.stringify(data.alpha.contract);
  const next = applyPin(data, 'alpha', candidate('1.2.4', hash('d')));
  assert.equal(JSON.stringify(next.alpha.contract), contractBefore);
  assert.deepEqual(next.alpha.pin, { version: '1.2.4', contentHash: hash('d') });
  assert.deepEqual(next.beta, data.beta);
  assert.deepEqual(next.gamma, data.gamma);
  assert.deepEqual(data.alpha.pin, { version: '1.2.3', contentHash: hash('a') });
});

test('V1 NOOP and RED have product mutation zero', () => {
  const data = registry();
  const noop = unchanged(data, () => applyPin(data, 'alpha', candidate('1.2.3', hash('a'))));
  const red = unchanged(data, () => applyPin(data, 'alpha', candidate('1.2.3', hash('f'))));
  assert.deepEqual(noop, data);
  assert.deepEqual(red, data);
});

test('V1 PRKey is stable and per CLI', () => {
  assert.equal(prKey('alpha'), 'cli-release:alpha');
  assert.notEqual(prKey('alpha'), prKey('gamma'));
});

test('V1 confirmed done judges existing evidence and resends no effect', () => {
  const plan = planApiEffect({ name: 'alpha', decision: decideCandidate(definition(), candidate('1.2.4')), observed: observed({ effect: 'CONFIRMED_DONE' }) });
  assert.deepEqual(plan, {
    state: 'JUDGE_EXISTING', reason: 'effect-already-exists', effectResend: 0, mutations: 0, prKey: 'cli-release:alpha',
  });
});

test('V1 confirmed not done executes only pending effect', () => {
  const plan = planApiEffect({ name: 'alpha', decision: decideCandidate(definition(), candidate('1.2.4')), observed: observed() });
  assert.equal(plan.state, 'EXECUTE_PENDING');
  assert.equal(plan.effectResend, 0);
  assert.equal(plan.mutations, 1);
});

test('V1 partial and unknown effects stop without retry', () => {
  for (const effect of ['PARTIAL_OR_FAILED', 'STILL_UNKNOWN']) {
    const plan = planApiEffect({ name: 'alpha', decision: decideCandidate(definition(), candidate('1.2.4')), observed: observed({ effect }) });
    assert.equal(plan.state, 'STOP');
    assert.equal(plan.effectResend, 0);
    assert.equal(plan.mutations, 0);
  }
});

test('V1 principal, lease, preimage, human/foreign edits, path and pointer guards fail closed', () => {
  const decision = decideCandidate(definition(), candidate('1.2.4'));
  const cases = [
    [{ principal: 'human' }, 'foreign-principal'],
    [{ head: hash('3').slice(0, 40) }, 'head-lease-mismatch'],
    [{ preimage: hash('4') }, 'target-preimage-mismatch'],
    [{ humanCommits: 1 }, 'human-or-foreign-commit'],
    [{ changedPaths: ['README.md'] }, 'unexpected-path'],
    [{ changedPointers: ['/alpha/contract/channel'] }, 'unexpected-json-pointer'],
  ];
  for (const [change, reason] of cases) {
    const plan = planApiEffect({ name: 'alpha', decision, observed: observed(change) });
    assert.equal(plan.state, 'STOP');
    assert.equal(plan.reason, reason);
    assert.equal(plan.mutations, 0);
    assert.equal(plan.effectResend, 0);
  }
});
