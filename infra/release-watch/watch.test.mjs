import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import {
  applyPin, bindCanonicalInput, compareVersions, createImmutableCommit, decideCandidate, decideThreeVersion, githubClient,
  generationBranch, inspectExistingBotPr, listAll, maintainOne, planApiEffect, prKey, prMarker, reconcileEffect,
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


function testGitObjectSha(type, content) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
  return createHash('sha1').update(Buffer.from(`${type} ${bytes.length}\0`)).update(bytes).digest('hex');
}

function testGitTreeSha(entries) {
  const sorted = entries.map((entry) => ({
    ...entry,
    mode: entry.mode.replace(/^0+(?=\d)/, ''),
    sortKey: Buffer.from(`${entry.path}${entry.type === 'tree' ? '/' : ''}`),
  })).sort((left, right) => Buffer.compare(left.sortKey, right.sortKey));
  const chunks = [];
  for (const entry of sorted) {
    chunks.push(Buffer.from(`${entry.mode} ${entry.path}\0`));
    chunks.push(Buffer.from(entry.sha, 'hex'));
  }
  return testGitObjectSha('tree', Buffer.concat(chunks));
}

function testGitCommitSha(body) {
  const identity = (value) => `${value.name} <${value.email}> ${Math.floor(Date.parse(value.date) / 1000)} +0000`;
  return testGitObjectSha('commit', [
    `tree ${body.tree}`,
    ...body.parents.map((parent) => `parent ${parent}`),
    `author ${identity(body.author)}`,
    `committer ${identity(body.committer)}`,
    '',
    body.message,
  ].join('\n'));
}

class GitObjectFixture {
  constructor(baseSha) {
    this.baseSha = baseSha;
    this.rootTree = 'a'.repeat(40);
    this.hostsTree = 'b'.repeat(40);
    this.profileTree = 'c'.repeat(40);
    this.calls = [];
    this.objects = { blobs: new Map(), trees: new Map(), commits: new Map() };
    this.unknownOnce = new Set();
    this.hiddenTrees = new Set();
    this.hideTreeUntilCommit = false;
    this.responseShaOverride = new Map();
    this.date = '2026-10-09T00:00:00.000Z';
    this.rootEntries = [
      { path: 'README.md', mode: '100644', type: 'blob', sha: 'd'.repeat(40) },
      { path: 'hosts', mode: '040000', type: 'tree', sha: this.hostsTree },
    ];
    this.hostsEntries = [
      { path: 'own', mode: '040000', type: 'tree', sha: 'e'.repeat(40) },
      { path: 'profile', mode: '040000', type: 'tree', sha: this.profileTree },
    ];
    this.profileEntries = [
      { path: 'nix.nix', mode: '100644', type: 'blob', sha: 'f'.repeat(40) },
      { path: 'releases.json', mode: '100644', type: 'blob', sha: '1'.repeat(40) },
    ];
  }
  failAfterApply(kind) { this.unknownOnce.add(kind); }
  delayTreeVisibilityUntilCommit() { this.hideTreeUntilCommit = true; }
  returnWrongSha(kind, sha = '9'.repeat(40)) { this.responseShaOverride.set(kind, sha); }
  maybeThrow(kind) {
    if (!this.unknownOnce.delete(kind)) return;
    throw new TypeError(`simulated timeout after ${kind}`);
  }
  expectedRoot(blobSha) {
    const profile = testGitTreeSha(this.profileEntries.map((entry) => entry.path === 'releases.json' ? { ...entry, sha: blobSha } : entry));
    const hosts = testGitTreeSha(this.hostsEntries.map((entry) => entry.path === 'profile' ? { ...entry, sha: profile } : entry));
    return testGitTreeSha(this.rootEntries.map((entry) => entry.path === 'hosts' ? { ...entry, sha: hosts } : entry));
  }
  api = async (method, path, body) => {
    this.calls.push({ method, path, body });
    if (method === 'GET' && path === `/git/commits/${this.baseSha}`) {
      return { sha: this.baseSha, tree: { sha: this.rootTree }, author: { date: this.date }, committer: { date: this.date } };
    }
    if (method === 'GET' && path === `/git/trees/${this.rootTree}`) return { sha: this.rootTree, truncated: false, tree: this.rootEntries };
    if (method === 'GET' && path === `/git/trees/${this.hostsTree}`) return { sha: this.hostsTree, truncated: false, tree: this.hostsEntries };
    if (method === 'GET' && path === `/git/trees/${this.profileTree}`) return { sha: this.profileTree, truncated: false, tree: this.profileEntries };
    if (method === 'GET' && path.startsWith('/git/blobs/')) return this.objects.blobs.get(path.slice('/git/blobs/'.length)) ?? null;
    if (method === 'POST' && path === '/git/blobs') {
      const bytes = Buffer.from(body.content, 'base64');
      const sha = testGitObjectSha('blob', bytes);
      this.objects.blobs.set(sha, { sha, encoding: 'base64', content: body.content });
      this.maybeThrow('blob');
      return { sha: this.responseShaOverride.get('blob') ?? sha };
    }
    if (method === 'GET' && path.startsWith('/git/trees/')) {
      const sha = path.slice('/git/trees/'.length);
      if (this.hiddenTrees.has(sha)) return null;
      return this.objects.trees.get(sha) ?? null;
    }
    if (method === 'POST' && path === '/git/trees') {
      const blobSha = body.tree[0].sha;
      const sha = this.expectedRoot(blobSha);
      this.objects.trees.set(sha, { sha, truncated: false, tree: [] });
      if (this.hideTreeUntilCommit) this.hiddenTrees.add(sha);
      this.maybeThrow('tree');
      return { sha: this.responseShaOverride.get('tree') ?? sha };
    }
    if (method === 'GET' && path.startsWith('/git/commits/')) return this.objects.commits.get(path.slice('/git/commits/'.length)) ?? null;
    if (method === 'POST' && path === '/git/commits') {
      const sha = testGitCommitSha(body);
      this.objects.commits.set(sha, {
        sha, tree: { sha: body.tree }, parents: body.parents.map((parent) => ({ sha: parent })),
        message: body.message, author: body.author, committer: body.committer,
      });
      this.hiddenTrees.delete(body.tree);
      this.maybeThrow('commit');
      return { sha: this.responseShaOverride.get('commit') ?? sha };
    }
    throw new Error(`unexpected object API ${method} ${path}`);
  };
}

function githubObjectView(fixture, {
  hideCreatedTree = false,
  messageView = (message) => message,
  shaView = (sha) => sha,
  contentsMode = 'exact',
} = {}) {
  return async (method, path, body) => {
    if (method === 'GET' && path.startsWith('/git/trees/')) {
      const sha = path.slice('/git/trees/'.length);
      if (hideCreatedTree && fixture.objects.trees.has(sha)) {
        fixture.calls.push({ method, path, body });
        return null;
      }
    }
    if (method === 'GET' && path.startsWith('/git/commits/')) {
      const value = await fixture.api(method, path, body);
      if (!value || typeof value.message !== 'string') return value;
      return { ...value, sha: shaView(value.sha), message: messageView(value.message) };
    }
    if (method === 'GET' && path.startsWith('/contents/hosts/profile/releases.json?')) {
      fixture.calls.push({ method, path, body });
      const ref = new URLSearchParams(path.split('?')[1]).get('ref');
      if (!fixture.objects.commits.has(ref) || contentsMode === 'missing') return null;
      const [blobSha, blob] = [...fixture.objects.blobs.entries()].at(-1) ?? [];
      if (!blobSha || !blob) return null;
      return {
        sha: contentsMode === 'wrong-sha' ? '9'.repeat(40) : blobSha,
        encoding: 'base64',
        content: contentsMode === 'wrong-bytes'
          ? Buffer.from('wrong registry bytes').toString('base64')
          : blob.content,
      };
    }
    return fixture.api(method, path, body);
  };
}

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
    if (method === 'PATCH' && path.startsWith('/git/refs/heads/')) {
      const branch = decodeURIComponent(path.slice('/git/refs/heads/'.length));
      this.refs.set(branch, body.sha);
      if (throwAfter('update-ref')) return null;
      return jsonResponse({ ref: `refs/heads/${branch}`, object: { sha: body.sha } });
    }
    if (method === 'GET' && path.startsWith('/compare/')) {
      const range = decodeURIComponent(path.slice('/compare/'.length));
      return jsonResponse({ merge_base_commit: { sha: range.split('...')[0] } });
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
  const manifest = Buffer.from(JSON.stringify({ version: '2.1.999', platforms: { 'linux-x64': { checksum: digest } } }));
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
  const manifest = Buffer.from(JSON.stringify({ version: '2.1.999', platforms: { 'linux-x64': { checksum: hex('a') } } }));
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

test('Claude signed manifest version is bound to the stable channel version', async () => {
  const bytes = Buffer.from('claude-selected-bytes');
  const digest = await import('node:crypto').then(({ createHash }) => createHash('sha256').update(bytes).digest('hex'));
  const manifest = Buffer.from(JSON.stringify({ version: '2.1.998', platforms: { 'linux-x64': { checksum: digest } } }));
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
  await assert.rejects(
    resolveCandidate('beta', definition('2.0.0', hex('b'), claudeContract()), { fetchImpl, runImpl }),
    /signed manifest version differs/,
  );
});

test('GitHub pagination validates Link/count/order and finite endpoint bounds', async () => {
  const repository = 'roccho-dev/windows';
  const page = (values, link = null) => new Response(JSON.stringify(values), {
    status: 200,
    headers: link ? { link } : {},
  });
  const next = (number) => `<https://api.github.com/repos/${repository}/items?per_page=100&page=${number}>; rel="next"`;

  const api = githubClient(repository, 'token', async (url) => {
    const number = Number(new URL(url).searchParams.get('page'));
    return number === 1 ? page(Array.from({ length: 100 }, (_, index) => index), next(2)) : page([100]);
  });
  assert.equal((await listAll(api, '/items', { maxPages: 2, maxItems: 101 })).length, 101);

  const exact = githubClient(repository, 'token', async () => page(Array.from({ length: 100 }, () => ({}))));
  assert.equal((await listAll(exact, '/items', { maxPages: 1, maxItems: 100 })).length, 100);

  const beyond = githubClient(repository, 'token', async () => page(Array.from({ length: 100 }, () => ({})), next(2)));
  await assert.rejects(listAll(beyond, '/items', { maxPages: 2, maxItems: 100 }), /continues beyond declared item limit/);

  const countMismatch = githubClient(repository, 'token', async () => page([1], next(2)));
  await assert.rejects(listAll(countMismatch, '/items', { maxPages: 2, maxItems: 101 }), /count\/header mismatch/);

  const missingPage = githubClient(repository, 'token', async () => page(Array.from({ length: 100 }, () => ({})), next(3)));
  await assert.rejects(listAll(missingPage, '/items', { maxPages: 3, maxItems: 250 }), /skipped a page/);

  const duplicatePage = githubClient(repository, 'token', async (url) => {
    const number = Number(new URL(url).searchParams.get('page'));
    return page(Array.from({ length: 100 }, () => ({})), next(number === 1 ? 2 : 2));
  });
  await assert.rejects(listAll(duplicatePage, '/items', { maxPages: 3, maxItems: 250 }), /skipped a page/);

  const noHeaders = async () => Array.from({ length: 100 }, () => ({}));
  await assert.rejects(listAll(noHeaders, '/items', { maxPages: 1, maxItems: 100 }), /exceeds declared limit/);
});

test('propose binds checkout and local registry to the same immutable canonical A', async () => {
  const data = registry();
  const base = 'a'.repeat(40);
  const api = async (method, path) => {
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: base } };
    if (method === 'GET' && path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) {
      return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    }
    throw new Error(`unexpected ${method} ${path}`);
  };
  const bound = await bindCanonicalInput({ api, checkoutSha: base, localRegistry: data });
  assert.equal(bound.baseSha, base);
  await assert.rejects(bindCanonicalInput({ api, checkoutSha: 'b'.repeat(40), localRegistry: data }), /advanced beyond checked-out source/);
  const changed = registry();
  changed.gamma.pin.version = '3.0.1';
  await assert.rejects(bindCanonicalInput({ api, checkoutSha: base, localRegistry: changed }), /differs from canonical A/);
});

test('canonical movement immediately before first effect stops with blob/tree/commit/ref/PR mutation zero', async () => {
  const data = registry();
  const repository = 'roccho-dev/windows';
  const base = 'a'.repeat(40);
  const moved = 'b'.repeat(40);
  const calls = [];
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
    if (method === 'GET' && path === `/git/ref/heads/${encodeURIComponent(generationBranch('alpha', base, candidate('1.2.4')))}`) return null;
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: moved } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  await assert.rejects(
    maintainOne({ repository, token: 'unused', baseSha: base, registry: data, name: 'alpha', candidate: candidate('1.2.4'), api }),
    /canonical A moved before mutation/,
  );
  assert.equal(calls.filter((call) => ['POST', 'PATCH', 'DELETE'].includes(call.method)).length, 0);
});

test('object POST response loss stops the phase; later deterministic readback never resends the completed object', async () => {
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  fixture.failAfterApply('blob');
  const receipts = [];
  const input = {
    api: fixture.api,
    parentShas: [base],
    treeBaseSha: base,
    registry: registry(),
    message: 'chore: deterministic object receipt',
    objectReceipts: receipts,
  };
  await assert.rejects(createImmutableCommit(input), /registry blob: POST failed or response was lost/);
  assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/git/blobs').length, 1);
  assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path !== '/git/blobs').length, 0);
  assert.equal(receipts[0].post.attempted, true);
  assert.match(receipts[0].post.error, /simulated timeout/);
  assert.equal(receipts[0].finalState, 'PARTIAL_OR_FAILED');

  fixture.calls.length = 0;
  const laterReceipts = [];
  const completed = await createImmutableCommit({ ...input, objectReceipts: laterReceipts });
  assert.match(completed.sha, /^[0-9a-f]{40}$/);
  assert.deepEqual(
    fixture.calls.filter((call) => call.method === 'POST').map((call) => call.path),
    ['/git/trees', '/git/commits'],
  );
  assert.equal(laterReceipts[0].finalState, 'CONFIRMED_DONE');
  assert.equal(laterReceipts[0].post.attempted, false);
});

test('raw tree 404 closes only through exact commit contents while preserving the direct 404 receipt', async () => {
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  const receipts = [];
  let leaseChecks = 0;
  const api = githubObjectView(fixture, {
    hideCreatedTree: true,
    messageView: (message) => message.endsWith('\n') ? message.slice(0, -1) : message,
  });
  const result = await createImmutableCommit({
    api,
    parentShas: [base],
    treeBaseSha: base,
    registry: registry(),
    message: 'chore: causal immutable closure',
    objectReceipts: receipts,
    beforeCommit: async () => { leaseChecks += 1; },
  });
  assert.match(result.sha, /^[0-9a-f]{40}$/);
  assert.equal(leaseChecks, 1);
  assert.deepEqual(
    fixture.calls.filter((call) => call.method === 'POST').map((call) => call.path),
    ['/git/blobs', '/git/trees', '/git/commits'],
  );
  const tree = receipts.find((receipt) => receipt.label === 'registry tree');
  const commit = receipts.find((receipt) => receipt.label === 'candidate commit');
  assert.equal(tree.method, 'POST');
  assert.equal(tree.path, '/git/trees');
  assert.equal(tree.post.responseSha, tree.expectedSha);
  assert.equal(tree.afterGET.state, 'CONFIRMED_NOT_DONE');
  assert.equal(tree.chainGET.state, 'CONFIRMED_NOT_DONE');
  assert.equal(tree.contentsGET.state, 'CONFIRMED_VIA_COMMIT_CONTENTS');
  assert.equal(tree.contentsGET.actualSha, receipts.find((receipt) => receipt.label === 'registry blob').expectedSha);
  assert.equal(tree.finalState, 'CONFIRMED_VIA_COMMIT_CONTENTS');
  assert.equal(tree.failure, null);
  assert.equal(commit.post.responseSha, commit.expectedSha);
  assert.equal(commit.afterGET.state, 'CONFIRMED_DONE');
  assert.equal(commit.chainGET.state, 'CONFIRMED_DONE');
});

test('second run preflights an existing exact commit and reaches ref with tree and commit POST zero', async () => {
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  const objectApi = githubObjectView(fixture, {
    hideCreatedTree: true,
    messageView: (message) => message.endsWith('\n') ? message.slice(0, -1) : message,
  });
  const input = {
    api: objectApi,
    parentShas: [base],
    treeBaseSha: base,
    registry: registry(),
    message: 'chore: cross-run deterministic resume',
  };

  const first = await createImmutableCommit(input);
  assert.match(first.sha, /^[0-9a-f]{40}$/);
  fixture.calls.length = 0;

  let refSha = null;
  const calls = [];
  const branch = 'bot/cross-run-resume';
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${branch}`) {
      return refSha ? { object: { sha: refSha } } : null;
    }
    if (method === 'POST' && path === '/git/refs') {
      refSha = body.sha;
      return { ref: body.ref, object: { sha: body.sha } };
    }
    return objectApi(method, path, body);
  };
  const receipts = [];
  const second = await createImmutableCommit({ ...input, api, objectReceipts: receipts });
  assert.equal(second.sha, first.sha);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/trees').length, 0);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/commits').length, 0);
  const tree = receipts.find((receipt) => receipt.label === 'registry tree');
  const commit = receipts.find((receipt) => receipt.label === 'candidate commit');
  assert.equal(tree.beforeGET.state, 'CONFIRMED_NOT_DONE');
  assert.equal(tree.contentsGET.state, 'CONFIRMED_VIA_COMMIT_CONTENTS');
  assert.equal(tree.finalState, 'CONFIRMED_VIA_COMMIT_CONTENTS');
  assert.equal(tree.post.attempted, false);
  assert.equal(commit.beforeGET.state, 'CONFIRMED_DONE');
  assert.equal(commit.finalState, 'CONFIRMED_DONE');
  assert.equal(commit.post.attempted, false);

  const refEffect = await reconcileRef({ api, branch, expectedOldSha: null, newSha: second.sha, create: true });
  assert.equal(refEffect.state, 'CONFIRMED_DONE');
  assert.equal(refEffect.sends, 1);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/refs').length, 1);
});

test('existing exact commit with missing blob or invalid contents stops before every mutation', async () => {
  for (const mode of ['missing-blob', 'missing', 'wrong-sha', 'wrong-bytes']) {
    const base = '3'.repeat(40);
    const fixture = new GitObjectFixture(base);
    const exactApi = githubObjectView(fixture, {
      hideCreatedTree: true,
      messageView: (message) => message.endsWith('\n') ? message.slice(0, -1) : message,
    });
    const input = {
      api: exactApi,
      parentShas: [base],
      treeBaseSha: base,
      registry: registry(),
      message: 'chore: preflight mismatch stop',
    };
    const first = await createImmutableCommit(input);
    assert.match(first.sha, /^[0-9a-f]{40}$/);
    if (mode === 'missing-blob') fixture.objects.blobs.clear();
    fixture.calls.length = 0;
    const api = githubObjectView(fixture, {
      hideCreatedTree: true,
      messageView: (message) => message.endsWith('\n') ? message.slice(0, -1) : message,
      contentsMode: mode === 'missing-blob' ? 'exact' : mode,
    });
    const receipts = [];
    await assert.rejects(
      createImmutableCommit({ ...input, api, objectReceipts: receipts }),
      mode === 'missing-blob' ? /immutable blob preflight/ : /immutable tree contents preflight/,
      mode,
    );
    assert.equal(fixture.calls.filter(({ method }) => ['POST', 'PATCH', 'DELETE'].includes(method)).length, 0, mode);
    assert.equal(fixture.calls.filter(({ path }) => path === '/git/refs' || path === '/pulls').length, 0, mode);
    const commit = receipts.find((receipt) => receipt.label === 'candidate commit');
    assert.equal(commit.beforeGET.state, 'CONFIRMED_DONE', mode);
    assert.equal(commit.post.attempted, false, mode);
  }
});

test('commit GET may omit exactly one terminal LF but internal, extra-LF or SHA differences remain RED', async () => {
  const cases = [
    ['omitted-terminal-lf', (message) => message.endsWith('\n') ? message.slice(0, -1) : message, (sha) => sha, true],
    ['internal-difference', (message) => message.replace('deterministic', 'different'), (sha) => sha, false],
    ['extra-terminal-lf', (message) => `${message}\n`, (sha) => sha, false],
    ['sha-difference', (message) => message, () => '9'.repeat(40), false],
  ];
  for (const [label, messageView, shaView, admitted] of cases) {
    const base = '3'.repeat(40);
    const fixture = new GitObjectFixture(base);
    const api = githubObjectView(fixture, { messageView, shaView });
    const input = {
      api, parentShas: [base], treeBaseSha: base, registry: registry(),
      message: 'chore: deterministic commit message',
    };
    if (admitted) {
      const result = await createImmutableCommit(input);
      assert.match(result.sha, /^[0-9a-f]{40}$/, label);
    } else {
      await assert.rejects(createImmutableCommit(input), /candidate commit: PARTIAL_OR_FAILED/, label);
    }
  }
});

test('contents closure mismatch or 404 stops before ref and PR without object resend', async () => {
  const repository = 'roccho-dev/windows';
  for (const mode of ['missing', 'wrong-sha', 'wrong-bytes']) {
    const base = '3'.repeat(40);
    const fixture = new GitObjectFixture(base);
    const receipts = [];
    const calls = [];
    const c = candidate('1.2.4', hex('d'));
    const branch = generationBranch('alpha', base, c);
    const objectApi = githubObjectView(fixture, {
      hideCreatedTree: true,
      messageView: (message) => message.endsWith('\n') ? message.slice(0, -1) : message,
      contentsMode: mode,
    });
    const api = async (method, path, body) => {
      calls.push({ method, path, body });
      if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
      if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${branch}`) return null;
      if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: base } };
      return objectApi(method, path, body);
    };
    await assert.rejects(
      maintainOne({
        repository, token: 'unused', baseSha: base, registry: registry(),
        name: 'alpha', candidate: c, api, objectReceipts: receipts,
      }),
      /immutable tree closure/,
      mode,
    );
    assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/trees').length, 1, mode);
    assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/commits').length, 1, mode);
    assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/refs').length, 0, mode);
    assert.equal(calls.filter(({ method, path }) => method === 'PATCH' && path.startsWith('/git/refs/')).length, 0, mode);
    assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/pulls').length, 0, mode);
    const tree = receipts.find((receipt) => receipt.label === 'registry tree');
    assert.equal(tree.chainGET.state, 'CONFIRMED_NOT_DONE', mode);
    assert.equal(tree.contentsGET.state, mode === 'missing' ? 'CONFIRMED_NOT_DONE' : 'PARTIAL_OR_FAILED', mode);
  }
});

test('tree POST response loss or response SHA mismatch stops before commit', async () => {
  for (const mode of ['response-loss', 'sha-mismatch']) {
    const base = '3'.repeat(40);
    const fixture = new GitObjectFixture(base);
    const receipts = [];
    if (mode === 'response-loss') fixture.failAfterApply('tree');
    else fixture.returnWrongSha('tree');
    await assert.rejects(
      createImmutableCommit({
        api: fixture.api,
        parentShas: [base],
        treeBaseSha: base,
        registry: registry(),
        message: `chore: ${mode}`,
        objectReceipts: receipts,
      }),
      mode === 'response-loss' ? /POST failed or response was lost/ : /POST response sha differs/,
    );
    assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/git/trees').length, 1, mode);
    assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/git/commits').length, 0, mode);
    const tree = receipts.find((receipt) => receipt.label === 'registry tree');
    assert.equal(tree.finalState, 'PARTIAL_OR_FAILED', mode);
    assert.equal(tree.method, 'POST', mode);
    assert.equal(tree.path, '/git/trees', mode);
    assert.match(tree.expectedSha, /^[0-9a-f]{40}$/, mode);
  }
});

test('commit failure or unknown stops before ref and PR with partial object evidence', async () => {
  const repository = 'roccho-dev/windows';
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  fixture.delayTreeVisibilityUntilCommit();
  fixture.failAfterApply('commit');
  const calls = [];
  const receipts = [];
  const c = candidate('1.2.4', hex('d'));
  const branch = generationBranch('alpha', base, c);
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
    if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${branch}`) return null;
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: base } };
    return fixture.api(method, path, body);
  };
  await assert.rejects(
    maintainOne({
      repository, token: 'unused', baseSha: base, registry: registry(),
      name: 'alpha', candidate: c, api, objectReceipts: receipts,
    }),
    /candidate commit: POST failed or response was lost/,
  );
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/refs').length, 0);
  assert.equal(calls.filter(({ method, path }) => method === 'PATCH' && path.startsWith('/git/refs/')).length, 0);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/pulls').length, 0);
  const commit = receipts.find((receipt) => receipt.label === 'candidate commit');
  assert.equal(commit.method, 'POST');
  assert.equal(commit.path, '/git/commits');
  assert.match(commit.expectedSha, /^[0-9a-f]{40}$/);
  assert.equal(commit.post.attempted, true);
  assert.match(commit.post.error, /simulated timeout/);
  assert.equal(commit.finalState, 'PARTIAL_OR_FAILED');
  assert.match(commit.failure, /POST failed or response was lost/);
});

test('existing deterministic blob and tree resume at the missing commit with object resend zero', async () => {
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  const input = {
    api: fixture.api,
    parentShas: [base],
    treeBaseSha: base,
    registry: registry(),
    message: 'chore: deterministic object receipt',
  };
  const complete = await createImmutableCommit(input);
  fixture.objects.commits.delete(complete.sha);
  fixture.calls.length = 0;

  const resumed = await createImmutableCommit(input);
  assert.equal(resumed.sha, complete.sha);
  assert.deepEqual({
    blob: resumed.receipts.blob.sends,
    tree: resumed.receipts.tree.sends,
    commit: resumed.receipts.commit.sends,
  }, { blob: 0, tree: 0, commit: 1 });
  assert.deepEqual(
    fixture.calls.filter((call) => call.method === 'POST').map((call) => call.path),
    ['/git/commits'],
  );
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
  const patches = fixture.calls.filter((call) => call.method === 'PATCH');
  assert.equal(patches.length, 1);
  assert.equal(patches[0].path, '/git/refs/heads/bot%2Fcli-release-alpha');
  assert.deepEqual(patches[0].body, { sha: '2'.repeat(40), force: false });
  assert.equal(fixture.calls.filter((call) => call.method === 'POST' && call.path === '/pulls').length, 0);
});

test('post-mutation absence is UNKNOWN and later deterministic readback never resends', async () => {
  let visible = false;
  let mutations = 0;
  const effect = {
    observe: async () => visible ? 'CONFIRMED_DONE' : 'CONFIRMED_NOT_DONE',
    mutate: async () => { mutations += 1; },
  };
  const first = await reconcileEffect(effect);
  assert.deepEqual({ state: first.state, sends: first.sends }, { state: 'STILL_UNKNOWN', sends: 1 });
  assert.equal(mutations, 1);
  visible = true;
  const second = await reconcileEffect(effect);
  assert.deepEqual({ state: second.state, sends: second.sends }, { state: 'CONFIRMED_DONE', sends: 0 });
  assert.equal(mutations, 1);
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
  const head = '1'.repeat(40);
  const base = '2'.repeat(40);
  const branch = generationBranch('alpha', base, candidate('1.2.4', hex('d')));
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [{
      number: 7, user: { login: BOT }, body: prMarker('alpha'),
      base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } },
    }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100&page=1') return [{ sha: '0'.repeat(40), author: { login: BOT }, committer: { login: BOT } }, { sha: head, author: { login: BOT }, committer: { login: BOT } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100&page=1') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${head}`)) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  const result = await inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha', candidate: candidate('1.2.4', hex('d')) });
  assert.equal(result.pendingPin.version, '1.2.4');
  assert.equal(result.observed.effect, 'CONFIRMED_DONE');
  assert.equal(result.observed.marker, prMarker('alpha'));
});

test('actual PR ownership reads every commit page and rejects a foreign commit after item 100', async () => {
  const data = registry();
  const pending = applyPin(data, 'alpha', candidate('1.2.4', hex('d')));
  const head = '1'.repeat(40);
  const base = '2'.repeat(40);
  const branch = generationBranch('alpha', base, candidate('1.2.4', hex('d')));
  const firstPage = Array.from({ length: 100 }, (_, index) => ({ sha: String(index).padStart(40, '0'), author: { login: BOT }, committer: { login: BOT } }));
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [{
      number: 7, user: { login: BOT }, body: prMarker('alpha'),
      base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } },
    }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100&page=1') return firstPage;
    if (path === '/pulls/7/commits?per_page=100&page=2') return [{ sha: head, author: { login: 'human' }, committer: { login: BOT } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100&page=1') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${head}`)) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  await assert.rejects(
    inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha', candidate: candidate('1.2.4', hex('d')) }),
    /author differs|committer differs/,
  );
});

test('generation identity includes A, candidate version and hash while PRKey stays stable', () => {
  const a = 'a'.repeat(40), b = 'b'.repeat(40);
  const c1 = candidate('1.2.4', hex('d'));
  const c2 = candidate('1.2.5', hex('e'));
  assert.notEqual(generationBranch('alpha', a, c1), generationBranch('alpha', b, c1));
  assert.notEqual(generationBranch('alpha', a, c1), generationBranch('alpha', a, c2));
  assert.match(generationBranch('alpha', a, c1), /-v1\.2\.4-hd{64}$/);
  assert.equal(prKey('alpha'), 'cli-release:alpha');
});


test('exact prepared candidate ref resumes PR only after response loss', async () => {
  const repository = 'roccho-dev/windows';
  const base = '3'.repeat(40);
  const c = candidate('1.2.4', hex('d'));
  const data = registry();
  const next = applyPin(data, 'alpha', c);
  const objectFixture = new GitObjectFixture(base);
  const prepared = await createImmutableCommit({
    api: objectFixture.api, parentShas: [base], treeBaseSha: base, registry: next,
    message: `chore: update alpha to ${c.version}\n\n${prKey('alpha')}`,
  });
  objectFixture.calls.length = 0;
  const branch = generationBranch('alpha', base, c);
  let openPr = null;
  const calls = [];
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: base } };
    if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: prepared.sha } };
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return openPr ? [openPr] : [];
    if (method === 'GET' && path.startsWith('/pulls?state=closed')) return [];
    if (method === 'GET' && path === `/commits/${prepared.sha}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (method === 'GET' && path === '/pulls/1/commits?per_page=100&page=1') return [{ sha: prepared.sha, author: { login: BOT }, committer: { login: BOT } }];
    if (method === 'GET' && path === '/pulls/1/files?per_page=100&page=1') return [{ filename: 'hosts/profile/releases.json' }];
    if (method === 'GET' && path.includes(`/contents/hosts/profile/releases.json?ref=${prepared.sha}`)) return { content: Buffer.from(JSON.stringify(next)).toString('base64') };
    if (method === 'GET' && path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    if (method === 'GET' && path.startsWith(`/compare/${base}...${prepared.sha}`)) return { merge_base_commit: { sha: base } };
    if (method === 'POST' && path === '/pulls') {
      openPr = {
        number: 1, html_url: 'https://github.test/pr/1', user: { login: BOT }, body: body.body,
        base: { ref: body.base, sha: base },
        head: { ref: body.head, sha: prepared.sha, repo: { full_name: repository } },
      };
      throw new TypeError('simulated response loss after PR create');
    }
    return objectFixture.api(method, path, body);
  };
  const result = await maintainOne({ repository, token: 'unused', baseSha: base, registry: data, name: 'alpha', candidate: c, api });
  assert.equal(result.state, 'DONE');
  assert.equal(result.recovery, 'REF_READY_NO_PR');
  assert.equal(result.prEffect.state, 'CONFIRMED_DONE');
  assert.equal(result.prEffect.sends, 1);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/pulls').length, 1);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path.startsWith('/git/')).length, 0);
  assert.equal(calls.filter(({ method }) => method === 'PATCH' || method === 'DELETE').length, 0);
});

test('closed-unmerged or foreign same-candidate ref holds with mutation zero', async () => {
  const repository = 'roccho-dev/windows';
  const base = '3'.repeat(40);
  const c = candidate('1.2.4', hex('d'));
  const branch = generationBranch('alpha', base, c);
  for (const mode of ['closed-unmerged', 'foreign-ref']) {
    const objectFixture = new GitObjectFixture(base);
    const calls = [];
    const api = async (method, path, body) => {
      calls.push({ method, path, body });
      if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
      if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: '9'.repeat(40) } };
      if (method === 'GET' && path.startsWith('/pulls?state=closed')) return mode === 'closed-unmerged'
        ? [{ number: 9, merged_at: null, head: { ref: branch, sha: '9'.repeat(40) } }] : [];
      return objectFixture.api(method, path, body);
    };
    await assert.rejects(
      inspectExistingBotPr({ api, repository, baseBranch: 'proposals', baseSha: base, registry: registry(), name: 'alpha', candidate: c }),
      mode === 'closed-unmerged' ? /closed PR evidence/ : /foreign or stale/,
      mode,
    );
    assert.equal(calls.filter(({ method }) => ['POST', 'PATCH', 'DELETE'].includes(method)).length, 0, mode);
  }
});

test('newer candidate is not blocked by an older closed generation ref', async () => {
  const repository = 'roccho-dev/windows';
  const base = '3'.repeat(40);
  const oldCandidate = candidate('1.2.4', hex('d'));
  const newerCandidate = candidate('1.2.5', hex('e'));
  const oldBranch = generationBranch('alpha', base, oldCandidate);
  const newBranch = generationBranch('alpha', base, newerCandidate);
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
    if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${newBranch}`) return null;
    if (method === 'GET' && decodeURIComponent(path) === `/git/ref/heads/${oldBranch}`) return { object: { sha: '9'.repeat(40) } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  const result = await inspectExistingBotPr({
    api, repository, baseBranch: 'proposals', baseSha: base, registry: registry(),
    name: 'alpha', candidate: newerCandidate,
  });
  assert.equal(result.exists, false);
  assert.equal(result.refReady, false);
  assert.equal(result.branch, newBranch);
  assert.notEqual(oldBranch, newBranch);
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

test('native Git graph: candidate-specific generation has one A pin delta for merge/squash/rebase', async () => {
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const firstCandidate = candidate('1.2.4', hex('d'));
  const secondCandidate = candidate('1.2.5', hex('e'));
  for (const mode of ['merge', 'squash', 'rebase']) {
    const dir = mkdtempSync(join(tmpdir(), 'watch-git-'));
    const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'bot', GIT_AUTHOR_EMAIL: 'bot@example.org', GIT_COMMITTER_NAME: 'bot', GIT_COMMITTER_EMAIL: 'bot@example.org' } }).trim();
    const commit = (value) => { writeFileSync(join(dir, 'pin'), `${value}\n`); git('add', 'pin'); git('commit', '-qm', value); };
    try {
      git('init', '-q', '-b', 'proposals'); commit('1');
      const firstA = git('rev-parse', 'HEAD');
      const firstBranch = generationBranch('alpha', firstA, firstCandidate);
      git('checkout', '-qb', firstBranch); commit('2');
      git('checkout', '-q', 'proposals');
      if (mode === 'merge') git('merge', '--no-ff', '-qm', 'adopt', firstBranch);
      if (mode === 'squash') { git('merge', '--squash', firstBranch); git('commit', '-qm', 'adopt'); }
      if (mode === 'rebase') { git('checkout', '-q', firstBranch); git('rebase', '-q', 'proposals'); git('checkout', '-q', 'proposals'); git('merge', '--ff-only', firstBranch); }
      const nextA = git('rev-parse', 'HEAD');
      const nextBranch = generationBranch('alpha', nextA, secondCandidate);
      git('checkout', '-qb', nextBranch); commit('3');
      assert.equal(git('rev-list', '--count', `proposals..${nextBranch}`), '1');
      assert.equal(git('diff', '--name-only', `proposals..${nextBranch}`), 'pin');
      git('checkout', '-q', 'proposals');
      if (mode === 'merge') git('merge', '--no-ff', '-qm', 'adopt2', nextBranch);
      if (mode === 'squash') { git('merge', '--squash', nextBranch); git('commit', '-qm', 'adopt2'); }
      if (mode === 'rebase') { git('checkout', '-q', nextBranch); git('rebase', '-q', 'proposals'); git('checkout', '-q', 'proposals'); git('merge', '--ff-only', nextBranch); }
      assert.equal(git('show', 'HEAD:pin'), '3');
      assert.equal(git('cat-file', '-t', firstA), 'commit');
      assert.equal(git('cat-file', '-t', firstBranch), 'commit');
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
});

test('canonical A moves before commit POST: receipt says stopped before POST and commit/ref/PR write zero', async () => {
  const base = '3'.repeat(40), moved = '4'.repeat(40);
  const fixture = new GitObjectFixture(base);
  const calls = [];
  const objectReceipts = [];
  let reads = 0;
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
    if (method === 'GET' && path === `/git/ref/heads/${encodeURIComponent(generationBranch('alpha', base, candidate('1.2.4')))}`) return null;
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: ++reads > 1 ? moved : base } };
    return fixture.api(method, path, body);
  };
  await assert.rejects(
    maintainOne({
      repository: 'roccho-dev/windows', token: 'unused', baseSha: base,
      registry: registry(), name: 'alpha', candidate: candidate('1.2.4'),
      api, objectReceipts,
    }),
    /candidate commit: pre-send guard failed: canonical A moved/,
  );
  const commitReceipt = objectReceipts.find((receipt) => receipt.label === 'candidate commit');
  assert.equal(commitReceipt.post.attempted, false);
  assert.equal(commitReceipt.post.responseSha, null);
  assert.equal(commitReceipt.post.error, null);
  assert.equal(commitReceipt.afterGET, null);
  assert.equal(commitReceipt.finalState, 'STOPPED_BEFORE_POST');
  assert.match(commitReceipt.failure, /pre-send guard failed: canonical A moved/);
  assert.doesNotMatch(commitReceipt.failure, /POST failed or response was lost/);
  assert.equal(calls.filter(({ method, path }) => method === 'PATCH' || method === 'DELETE' || method === 'POST' && ['/git/refs', '/pulls'].includes(path)).length, 0);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/commits').length, 0);
});

test('PR creation preflight rejects known base or generation mismatch with POST zero', async () => {
  const base = '3'.repeat(40);
  const expectedHead = '1'.repeat(40);
  const c = candidate('1.2.4', hex('d'));
  for (const mismatch of ['base', 'head']) {
    const fixture = new ProtocolFixture();
    const api = githubClient(fixture.repository, 'token', fixture.fetch);
    const branch = generationBranch('alpha', base, c);
    fixture.refs.set('proposals', mismatch === 'base' ? '4'.repeat(40) : base);
    fixture.refs.set(branch, mismatch === 'head' ? '2'.repeat(40) : expectedHead);
    const result = await reconcilePrCreate({
      api, repository: fixture.repository, baseBranch: 'proposals', baseSha: base,
      branch, name: 'alpha', title: 'update', body: prMarker('alpha'),
      expectedHead, expectedRegistry: registry(),
    });
    assert.equal(result.state, 'PARTIAL_OR_FAILED', mismatch);
    assert.equal(result.sends, 0, mismatch);
    assert.equal(fixture.calls.filter(({ method, path }) => method === 'POST' && path === '/pulls').length, 0, mismatch);
  }
});

test('PR commit and head require present bot author and committer; mixed or missing is RED', async () => {
  const base = '2'.repeat(40), head = '1'.repeat(40);
  const c = candidate('1.2.4', hex('d'));
  const branch = generationBranch('alpha', base, c);
  const data = registry();
  const next = applyPin(data, 'alpha', c);
  const cases = [
    ['page-author-missing', { pageAuthor: null }],
    ['page-committer-missing', { pageCommitter: null }],
    ['head-author-missing', { headAuthor: null }],
    ['head-committer-missing', { headCommitter: null }],
    ['page-mixed', { pageCommitter: 'human' }],
    ['head-mixed', { headCommitter: 'human' }],
  ];
  for (const [label, change] of cases) {
    const actor = (login) => login === null ? null : { login: login ?? BOT };
    const api = async (method, path) => {
      if (path.startsWith('/pulls?state=open')) return [{ number: 7, user: { login: BOT }, body: prMarker('alpha'), base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } } }];
      if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
      if (path.startsWith('/pulls/7/commits?')) return [{ author: actor(change.pageAuthor), committer: actor(change.pageCommitter) }];
      if (path === `/commits/${head}`) return { author: actor(change.headAuthor), committer: actor(change.headCommitter) };
      if (path.startsWith('/pulls/7/files?')) return [{ filename: 'hosts/profile/releases.json' }];
      if (path.includes(`ref=${head}`)) return { content: Buffer.from(JSON.stringify(next)).toString('base64') };
      if (path.includes(`ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
      if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
      throw new Error(`unexpected ${method} ${path}`);
    };
    await assert.rejects(
      inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha', candidate: c }),
      /author differs|committer differs/,
      label,
    );
  }
});
