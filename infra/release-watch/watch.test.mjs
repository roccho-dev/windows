import assert from 'node:assert/strict';
import test from 'node:test';
import {
  applyPin, compareVersions, decideCandidate, decideThreeVersion, githubClient,
  inspectExistingBotPr, planApiEffect, prKey, prMarker, reconcileEffect,
  reconcilePrCreate, reconcileRef, releaseVersions, resolveCandidate, validateRegistry,
} from './watch.mjs';

const hex = (char) => char.repeat(64);
const fp = '31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE';
const codexContract = (overrides = {}) => ({
  sourceKind: 'github-release', officialSource: 'openai/codex', channel: 'stable', versionScheme: 'semver',
  platform: 'x86_64-unknown-linux-musl', assetSelector: 'codex-package-x86_64-unknown-linux-musl.tar.gz',
  verifyKind: 'sigstore-bundle', packageShape: 'codex-musl-tar',
  proof: {
    kind: 'sigstore-bundle', assetSuffix: '.sigstore',
    certificateIdentityPrefix: 'https://github.com/openai/codex/.github/workflows/rust-release.yml@refs/tags/rust-v',
    certificateOidcIssuer: 'https://token.actions.githubusercontent.com',
  }, ...overrides,
});
const claudeContract = () => ({
  sourceKind: 'claude-manifest', officialSource: 'https://downloads.claude.ai/claude-code-releases',
  channel: 'stable', versionScheme: 'semver', platform: 'linux-x64', assetSelector: 'claude',
  verifyKind: 'gpg-signed-manifest', packageShape: 'single-glibc-executable',
  proof: {
    kind: 'gpg-signed-manifest', manifestName: 'manifest.json', signatureName: 'manifest.json.sig',
    keyUrl: 'https://downloads.claude.ai/keys/claude-code.asc', keyFingerprint: fp,
  },
});
const definition = (version = '1.2.3', contentHash = hex('a'), contract = codexContract()) => ({ contract, pin: { version, contentHash } });
const registry = () => ({ alpha: definition(), beta: definition('2.0.0', hex('b'), claudeContract()), gamma: definition('3.0.0', hex('c')) });
const candidate = (version, contentHash = hex('d'), proof = true) => ({ version, contentHash, proof });

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });
}
function bytesResponse(value, status = 200) {
  return new Response(value, { status });
}

class ProtocolFixture {
  constructor(repository = 'roccho-dev/windows') {
    this.repository = repository;
    this.refs = new Map();
    this.prs = [];
    this.calls = [];
    this.unknownOnce = new Set();
  }
  failAfterApply(key) { this.unknownOnce.add(key); }
  fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const parsed = new URL(url);
    const prefix = `/repos/${this.repository}`;
    const path = parsed.pathname.slice(prefix.length) + parsed.search;
    const body = options.body ? JSON.parse(options.body) : null;
    this.calls.push({ method, path, body });
    const throwAfter = (key) => {
      if (!this.unknownOnce.delete(key)) return false;
      throw new TypeError(`simulated timeout after ${key}`);
    };
    if (method === 'GET' && path.startsWith('/git/ref/heads/')) {
      const branch = decodeURIComponent(path.slice('/git/ref/heads/'.length));
      const sha = this.refs.get(branch);
      return sha ? jsonResponse({ ref: `refs/heads/${branch}`, object: { sha } }) : jsonResponse({ message: 'not found' }, 404);
    }
    if (method === 'POST' && path === '/git/refs') {
      const branch = body.ref.slice('refs/heads/'.length);
      this.refs.set(branch, body.sha);
      if (throwAfter('create-ref')) return null;
      return jsonResponse({ ref: body.ref, object: { sha: body.sha } }, 201);
    }
    if (method === 'PATCH' && path.startsWith('/git/ref/heads/')) {
      const branch = decodeURIComponent(path.slice('/git/ref/heads/'.length));
      this.refs.set(branch, body.sha);
      if (throwAfter('update-ref')) return null;
      return jsonResponse({ ref: `refs/heads/${branch}`, object: { sha: body.sha } });
    }
    if (method === 'GET' && path.startsWith('/pulls?')) {
      const query = new URLSearchParams(path.split('?')[1]);
      const branch = decodeURIComponent(query.get('head')).split(':').slice(1).join(':');
      return jsonResponse(this.prs.filter((pr) => pr.head.ref === branch));
    }
    if (method === 'POST' && path === '/pulls') {
      const pr = {
        number: this.prs.length + 1, html_url: `https://github.test/pr/${this.prs.length + 1}`,
        user: { login: 'github-actions[bot]' }, body: body.body,
        base: { ref: body.base }, head: { ref: body.head, sha: this.refs.get(body.head), repo: { full_name: this.repository } },
      };
      this.prs.push(pr);
      if (throwAfter('create-pr')) return null;
      return jsonResponse(pr, 201);
    }
    return jsonResponse({ message: `unhandled ${method} ${path}` }, 500);
  };
}

test('V0 strict signed D_i schema and third same-kind registration', () => {
  const data = registry();
  assert.equal(validateRegistry(data), data);
  assert.deepEqual(releaseVersions(data), { alpha: '1.2.3', beta: '2.0.0', gamma: '3.0.0' });
  assert.equal(data.alpha.contract.verifyKind, data.gamma.contract.verifyKind);
  assert.throws(() => validateRegistry({ alpha: { ...data.alpha, extra: true } }), /keys differ/);
  const weakened = registry();
  weakened.alpha.contract.verifyKind = 'github-asset-digest';
  assert.throws(() => validateRegistry(weakened), /GitHub release proof differs/);
});

test('V1 versions are ordered only as stable semver', () => {
  assert.equal(compareVersions('1.2.3', '1.2.3'), 0);
  assert.equal(compareVersions('1.2.4', '1.2.3'), 1);
  assert.equal(compareVersions('1.2.2', '1.2.3'), -1);
  assert.equal(compareVersions('latest', '1.2.3'), null);
});

test('V1 proven resolver evidence is admitted without weakening required candidate fields', () => {
  const full = {
    ...candidate('1.2.4', hex('d')),
    sourceUrl: 'https://example.invalid/tool.tar.gz',
    selectedBytes: 123,
    proofReceipt: { kind: 'sigstore-bundle', identity: 'issuer-bound' },
  };
  assert.equal(decideCandidate(definition(), full).state, 'UPDATE');
  assert.throws(() => decideCandidate(definition(), { ...full, arbitrary: true }), /unexpected keys/);
  assert.throws(() => decideCandidate(definition(), { proof: true, version: '1.2.4' }), /missing required key: contentHash/);
});

test('V1 A/B/C monotonicity never reverses and equal-version hash drift is RED', () => {
  const A = definition('2.0.0', hex('a'));
  assert.equal(decideThreeVersion(A, candidate('1.9.9'), null).reason, 'C-before-A');
  assert.equal(decideThreeVersion(A, candidate('2.0.0', hex('a')), null).state, 'NOOP');
  assert.equal(decideThreeVersion(A, candidate('2.0.0', hex('b')), null).reason, 'same-version-hash-drift');
  assert.equal(decideThreeVersion(A, candidate('2.2.0', hex('e')), { version: '2.1.0', contentHash: hex('d') }).action, 'ADVANCE');
  assert.equal(decideThreeVersion(A, candidate('2.1.0', hex('d')), { version: '2.1.0', contentHash: hex('d') }).action, 'RESUME');
  assert.equal(decideThreeVersion(A, candidate('2.0.5', hex('e')), { version: '2.1.0', contentHash: hex('d') }).reason, 'C-before-B');
  assert.equal(decideThreeVersion(A, candidate('2.1.0', hex('e')), { version: '2.1.0', contentHash: hex('d') }).reason, 'C-B-same-version-hash-drift');
  assert.equal(decideThreeVersion(A, candidate('2.1.0', hex('d'), false), null).reason, 'proof-failed');
});

test('V1 pin update mutates only the two admitted pointers and never K_i', () => {
  const data = registry();
  const before = JSON.stringify(data.alpha.contract);
  const next = applyPin(data, 'alpha', candidate('1.2.4', hex('d')));
  assert.equal(JSON.stringify(next.alpha.contract), before);
  assert.deepEqual(next.alpha.pin, { version: '1.2.4', contentHash: hex('d') });
  assert.deepEqual(data.alpha.pin, { version: '1.2.3', contentHash: hex('a') });
});

test('Codex proof verifies selected bytes, GitHub digest, identity, issuer and Sigstore bundle', async () => {
  const bytes = Buffer.from('codex-selected-bytes');
  const digest = await import('node:crypto').then(({ createHash }) => createHash('sha256').update(bytes).digest('hex'));
  const release = {
    draft: false, prerelease: false, tag_name: 'rust-v1.2.4',
    assets: [
      { name: codexContract().assetSelector, digest: `sha256:${digest}`, browser_download_url: 'https://download.test/codex' },
      { name: `${codexContract().assetSelector}.sigstore`, browser_download_url: 'https://download.test/codex.sigstore' },
    ],
  };
  const calls = [];
  const fetchImpl = async (url) => {
    if (url.includes('/releases/latest')) return jsonResponse(release);
    if (url.endsWith('.sigstore')) return bytesResponse('bundle');
    if (url.endsWith('/codex')) return bytesResponse(bytes);
    throw new Error(`unexpected ${url}`);
  };
  const runImpl = async (command, args) => {
    calls.push({ command, args });
    return { code: 0, stdout: 'Verified OK', stderr: '' };
  };
  const resolved = await resolveCandidate('alpha', definition('1.2.3', hex('a')), { fetchImpl, runImpl });
  assert.equal(resolved.contentHash, digest);
  assert.equal(resolved.selectedBytes, bytes.length);
  assert.equal(resolved.proof, true);
  assert.deepEqual(calls[0].args.slice(0, 2), ['verify-blob', '--offline']);
  assert.ok(calls[0].args.includes('https://github.com/openai/codex/.github/workflows/rust-release.yml@refs/tags/rust-v1.2.4'));
  assert.ok(calls[0].args.includes('https://token.actions.githubusercontent.com'));
});

test('Codex proof fails closed when selected bytes differ from official digest', async () => {
  const contract = codexContract();
  const release = { draft: false, prerelease: false, tag_name: 'rust-v1.2.4', assets: [
    { name: contract.assetSelector, digest: `sha256:${hex('a')}`, browser_download_url: 'https://download.test/codex' },
    { name: `${contract.assetSelector}.sigstore`, browser_download_url: 'https://download.test/codex.sigstore' },
  ] };
  const fetchImpl = async (url) => url.includes('/releases/latest') ? jsonResponse(release) : bytesResponse('different');
  await assert.rejects(resolveCandidate('alpha', definition(), { fetchImpl, runImpl: async () => ({ code: 0, stdout: '', stderr: '' }) }), /selected bytes differ/);
});

test('Claude proof verifies exact GPG fingerprint, signed manifest and selected binary bytes', async () => {
  const bytes = Buffer.from('claude-selected-bytes');
  const digest = await import('node:crypto').then(({ createHash }) => createHash('sha256').update(bytes).digest('hex'));
  const manifest = Buffer.from(JSON.stringify({ platforms: { 'linux-x64': { checksum: digest } } }));
  const fetchImpl = async (url) => {
    if (url.endsWith('/stable')) return bytesResponse('2.1.999');
    if (url.endsWith('/manifest.json')) return bytesResponse(manifest);
    if (url.endsWith('/manifest.json.sig')) return bytesResponse('signature');
    if (url.endsWith('/claude-code.asc')) return bytesResponse('public-key');
    if (url.endsWith('/linux-x64/claude')) return bytesResponse(bytes);
    throw new Error(`unexpected ${url}`);
  };
  const runImpl = async (_command, args) => {
    if (args.includes('--import')) return { code: 0, stdout: '', stderr: '' };
    if (args.includes('--fingerprint')) return { code: 0, stdout: `fpr:::::::::${fp}:\n`, stderr: '' };
    if (args.includes('--verify')) return { code: 0, stdout: `[GNUPG:] VALIDSIG ${fp} 2026-01-01 0 4 0 1 10 00 ${fp}\n`, stderr: '' };
    throw new Error(`unexpected gpg args ${args.join(' ')}`);
  };
  const resolved = await resolveCandidate('beta', definition('2.0.0', hex('b'), claudeContract()), { fetchImpl, runImpl });
  assert.equal(resolved.version, '2.1.999');
  assert.equal(resolved.contentHash, digest);
  assert.equal(resolved.proofReceipt.keyFingerprint, fp);
});

test('Claude proof rejects wrong key fingerprint and byte drift', async () => {
  const bytes = Buffer.from('bytes');
  const manifest = Buffer.from(JSON.stringify({ platforms: { 'linux-x64': { checksum: hex('a') } } }));
  const fetchImpl = async (url) => {
    if (url.endsWith('/stable')) return bytesResponse('2.1.999');
    if (url.endsWith('/manifest.json')) return bytesResponse(manifest);
    if (url.endsWith('/manifest.json.sig')) return bytesResponse('signature');
    if (url.endsWith('/claude-code.asc')) return bytesResponse('key');
    return bytesResponse(bytes);
  };
  const wrongKey = async (_command, args) => args.includes('--fingerprint')
    ? { code: 0, stdout: `fpr:::::::::${'F'.repeat(40)}:\n`, stderr: '' }
    : { code: 0, stdout: '', stderr: '' };
  await assert.rejects(resolveCandidate('beta', definition('2.0.0', hex('b'), claudeContract()), { fetchImpl, runImpl: wrongKey }), /fingerprint mismatch/);
});

test('unknown-after-success ref create/update and PR create reconcile read-only with resend zero', async () => {
  const fixture = new ProtocolFixture();
  const api = githubClient(fixture.repository, 'token', fixture.fetch);
  fixture.failAfterApply('create-ref');
  const create = await reconcileRef({ api, branch: 'bot/cli-release-alpha', expectedOldSha: null, newSha: '1'.repeat(40), create: true });
  assert.deepEqual({ state: create.state, sends: create.sends }, { state: 'CONFIRMED_DONE', sends: 1 });
  assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/git/refs').length, 1);
  fixture.failAfterApply('update-ref');
  const update = await reconcileRef({ api, branch: 'bot/cli-release-alpha', expectedOldSha: '1'.repeat(40), newSha: '2'.repeat(40), create: false });
  assert.deepEqual({ state: update.state, sends: update.sends }, { state: 'CONFIRMED_DONE', sends: 1 });
  assert.equal(fixture.calls.filter((call) => call.method === 'PATCH').length, 1);
  fixture.failAfterApply('create-pr');
  const pr = await reconcilePrCreate({ api, repository: fixture.repository, baseBranch: 'proposals', branch: 'bot/cli-release-alpha', name: 'alpha', title: 'update', body: prMarker('alpha') });
  assert.deepEqual({ state: pr.state, sends: pr.sends }, { state: 'CONFIRMED_DONE', sends: 1 });
  assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/pulls').length, 1);
});

test('partial/unknown effects stop and never resend', async () => {
  let sends = 0;
  for (const first of ['PARTIAL_OR_FAILED', 'STILL_UNKNOWN']) {
    const result = await reconcileEffect({ observe: async () => first, mutate: async () => { sends += 1; } });
    assert.equal(result.sends, 0);
  }
  assert.equal(sends, 0);
});

test('actual PR acceptance requires author, marker/PRKey, branch, actor, lease, preimage, path and pointers', async () => {
  const data = registry();
  const pending = applyPin(data, 'alpha', candidate('1.2.4', hex('d')));
  const branch = 'bot/cli-release-alpha';
  const head = '1'.repeat(40);
  const base = '2'.repeat(40);
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?')) return [{ number: 7, user: { login: BOT }, body: prMarker('alpha'), base: { ref: 'proposals' }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } } }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100') return [{ sha: '0'.repeat(40), author: { login: BOT } }, { sha: head, author: { login: BOT } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.startsWith('/contents/hosts/profile/releases.json')) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  const result = await inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha' });
  assert.equal(result.pendingPin.version, '1.2.4');
  assert.equal(result.observed.effect, 'CONFIRMED_DONE');
  assert.equal(result.observed.marker, prMarker('alpha'));
});

test('actual PR acceptance rejects any foreign commit in an otherwise valid bot PR', async () => {
  const data = registry();
  const pending = applyPin(data, 'alpha', candidate('1.2.4', hex('d')));
  const branch = 'bot/cli-release-alpha';
  const head = '1'.repeat(40);
  const base = '2'.repeat(40);
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?')) return [{ number: 7, user: { login: BOT }, body: prMarker('alpha'), base: { ref: 'proposals' }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } } }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100') return [{ sha: head, author: { login: 'human' } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.startsWith('/contents/hosts/profile/releases.json')) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  await assert.rejects(
    inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha' }),
    /human or foreign commit/,
  );
});
const BOT = 'github-actions[bot]';

test('planApiEffect fails closed on author, marker, actor, lease, preimage, path and pointer contamination', () => {
  const base = {
    effect: 'CONFIRMED_NOT_DONE', principal: BOT, expectedPrincipal: BOT,
    marker: prMarker('alpha'), branch: 'bot/cli-release-alpha', headActor: BOT,
    head: '1'.repeat(40), expectedHead: '1'.repeat(40), preimage: '2'.repeat(40), expectedPreimage: '2'.repeat(40),
    humanCommits: 0, changedPaths: ['hosts/profile/releases.json'], changedPointers: ['/alpha/pin/version', '/alpha/pin/contentHash'],
  };
  const decision = decideCandidate(definition(), candidate('1.2.4'));
  for (const [change, reason] of [
    [{ principal: 'human' }, 'foreign-principal'], [{ marker: '<!-- other -->' }, 'PRKey-marker-mismatch'],
    [{ branch: 'other' }, 'fixed-branch-mismatch'], [{ headActor: 'human' }, 'foreign-head-actor'],
    [{ head: '3'.repeat(40) }, 'head-lease-mismatch'], [{ preimage: '4'.repeat(40) }, 'target-preimage-mismatch'],
    [{ humanCommits: 1 }, 'human-or-foreign-commit'], [{ changedPaths: ['README.md'] }, 'unexpected-path'],
    [{ changedPointers: ['/alpha/contract/channel'] }, 'unexpected-json-pointer'],
  ]) {
    const plan = planApiEffect({ name: 'alpha', decision, observed: { ...base, ...change } });
    assert.equal(plan.state, 'STOP');
    assert.equal(plan.reason, reason);
    assert.equal(plan.effectResend, 0);
  }
  assert.equal(prKey('alpha'), 'cli-release:alpha');
});
