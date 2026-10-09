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
      return { sha };
    }
    if (method === 'GET' && path.startsWith('/git/trees/')) return this.objects.trees.get(path.slice('/git/trees/'.length)) ?? null;
    if (method === 'POST' && path === '/git/trees') {
      const blobSha = body.tree[0].sha;
      const sha = this.expectedRoot(blobSha);
      this.objects.trees.set(sha, { sha, truncated: false, tree: [] });
      this.maybeThrow('tree');
      return { sha };
    }
    if (method === 'GET' && path.startsWith('/git/commits/')) return this.objects.commits.get(path.slice('/git/commits/'.length)) ?? null;
    if (method === 'POST' && path === '/git/commits') {
      const sha = testGitCommitSha(body);
      this.objects.commits.set(sha, {
        sha, tree: { sha: body.tree }, parents: body.parents.map((parent) => ({ sha: parent })),
        message: body.message, author: body.author, committer: body.committer,
      });
      this.maybeThrow('commit');
      return { sha };
    }
    throw new Error(`unexpected object API ${method} ${path}`);
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
    if (method === 'GET' && path === `/git/ref/heads/${encodeURIComponent(generationBranch('alpha', base))}`) return null;
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: moved } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  await assert.rejects(
    maintainOne({ repository, token: 'unused', baseSha: base, registry: data, name: 'alpha', candidate: candidate('1.2.4'), api }),
    /canonical A moved before mutation/,
  );
  assert.equal(calls.filter((call) => ['POST', 'PATCH', 'DELETE'].includes(call.method)).length, 0);
});

test('blob/tree/commit success with lost responses is read back once and never replayed', async () => {
  const base = '3'.repeat(40);
  const fixture = new GitObjectFixture(base);
  fixture.failAfterApply('blob');
  fixture.failAfterApply('tree');
  fixture.failAfterApply('commit');
  const input = {
    api: fixture.api,
    parentShas: [base],
    treeBaseSha: base,
    registry: registry(),
    message: 'chore: deterministic object receipt',
  };
  const first = await createImmutableCommit(input);
  assert.deepEqual({
    blob: first.receipts.blob.sends,
    tree: first.receipts.tree.sends,
    commit: first.receipts.commit.sends,
  }, { blob: 1, tree: 1, commit: 1 });
  const posts = fixture.calls.filter((call) => call.method === 'POST').length;
  assert.equal(posts, 3);

  const second = await createImmutableCommit(input);
  assert.equal(second.sha, first.sha);
  assert.deepEqual({
    blob: second.receipts.blob.sends,
    tree: second.receipts.tree.sends,
    commit: second.receipts.commit.sends,
  }, { blob: 0, tree: 0, commit: 0 });
  assert.equal(fixture.calls.filter((call) => call.method === 'POST').length, posts);
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
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [{
      number: 7, user: { login: BOT }, body: prMarker('alpha'),
      base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } },
    }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100&page=1') return [{ sha: '0'.repeat(40), author: { login: BOT } }, { sha: head, author: { login: BOT } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100&page=1') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${head}`)) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  const result = await inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha' });
  assert.equal(result.pendingPin.version, '1.2.4');
  assert.equal(result.observed.effect, 'CONFIRMED_DONE');
  assert.equal(result.observed.marker, prMarker('alpha'));
});

test('actual PR ownership reads every commit page and rejects a foreign commit after item 100', async () => {
  const data = registry();
  const pending = applyPin(data, 'alpha', candidate('1.2.4', hex('d')));
  const branch = 'bot/cli-release-alpha';
  const head = '1'.repeat(40);
  const base = '2'.repeat(40);
  const firstPage = Array.from({ length: 100 }, (_, index) => ({ sha: String(index).padStart(40, '0'), author: { login: BOT } }));
  const api = async (method, path) => {
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [{
      number: 7, user: { login: BOT }, body: prMarker('alpha'),
      base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } },
    }];
    if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
    if (path === '/pulls/7/commits?per_page=100&page=1') return firstPage;
    if (path === '/pulls/7/commits?per_page=100&page=2') return [{ sha: head, author: { login: 'human' } }];
    if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: BOT } };
    if (path === '/pulls/7/files?per_page=100&page=1') return [{ filename: 'hosts/profile/releases.json' }];
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${head}`)) return { content: Buffer.from(JSON.stringify(pending)).toString('base64') };
    if (path.includes(`/contents/hosts/profile/releases.json?ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
    if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  await assert.rejects(
    inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha' }),
    /human or foreign commit/,
  );
});

test('generation branch changes with canonical A; stable PRKey and no retained ref rewrite', () => {
  const a = 'a'.repeat(40), b = 'b'.repeat(40);
  assert.notEqual(generationBranch('alpha', a), generationBranch('alpha', b));
  assert.equal(prKey('alpha'), 'cli-release:alpha');
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

test('native Git graph: generation candidate has only A pin delta for merge/squash/rebase', async () => {
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  for (const mode of ['merge', 'squash', 'rebase']) {
    const dir = mkdtempSync(join(tmpdir(), 'watch-git-'));
    const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'bot', GIT_AUTHOR_EMAIL: 'bot@example.org', GIT_COMMITTER_NAME: 'bot', GIT_COMMITTER_EMAIL: 'bot@example.org' } }).trim();
    const commit = (value) => { writeFileSync(join(dir, 'pin'), `${value}\n`); git('add', 'pin'); git('commit', '-qm', value); };
    try {
      git('init', '-q', '-b', 'proposals'); commit('1');
      const firstA = git('rev-parse', 'HEAD');
      git('checkout', '-qb', generationBranch('alpha', firstA)); commit('2');
      git('checkout', '-q', 'proposals');
      if (mode === 'merge') git('merge', '--no-ff', '-qm', 'adopt', generationBranch('alpha', firstA));
      if (mode === 'squash') { git('merge', '--squash', generationBranch('alpha', firstA)); git('commit', '-qm', 'adopt'); }
      if (mode === 'rebase') { git('checkout', '-q', generationBranch('alpha', firstA)); git('rebase', '-q', 'proposals'); git('checkout', '-q', 'proposals'); git('merge', '--ff-only', generationBranch('alpha', firstA)); }
      const nextA = git('rev-parse', 'HEAD');
      git('checkout', '-qb', generationBranch('alpha', nextA)); commit('3');
      assert.equal(git('rev-list', '--count', `proposals..${generationBranch('alpha', nextA)}`), '1');
      assert.equal(git('diff', '--name-only', `proposals..${generationBranch('alpha', nextA)}`), 'pin');
      git('checkout', '-q', 'proposals');
      if (mode === 'merge') git('merge', '--no-ff', '-qm', 'adopt2', generationBranch('alpha', nextA));
      if (mode === 'squash') { git('merge', '--squash', generationBranch('alpha', nextA)); git('commit', '-qm', 'adopt2'); }
      if (mode === 'rebase') { git('checkout', '-q', generationBranch('alpha', nextA)); git('rebase', '-q', 'proposals'); git('checkout', '-q', 'proposals'); git('merge', '--ff-only', generationBranch('alpha', nextA)); }
      assert.equal(git('show', 'HEAD:pin'), '3');
      assert.equal(git('cat-file', '-t', firstA), 'commit');
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
});

test('canonical A moves after immutable objects: no ref or PR write', async () => {
  const base = '3'.repeat(40), moved = '4'.repeat(40);
  const fixture = new GitObjectFixture(base);
  const calls = [];
  let reads = 0;
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === 'GET' && path.startsWith('/pulls?state=open')) return [];
    if (method === 'GET' && path === `/git/ref/heads/${encodeURIComponent(generationBranch('alpha', base))}`) return null;
    if (method === 'GET' && path === '/git/ref/heads/proposals') return { object: { sha: ++reads > 1 ? moved : base } };
    return fixture.api(method, path, body);
  };
  await assert.rejects(maintainOne({ repository: 'roccho-dev/windows', token: 'unused', baseSha: base, registry: registry(), name: 'alpha', candidate: candidate('1.2.4'), api }), /canonical A moved/);
  assert.equal(calls.filter(({ method, path }) => method === 'PATCH' || method === 'DELETE' || method === 'POST' && ['/git/refs', '/pulls'].includes(path)).length, 0);
  assert.equal(calls.filter(({ method, path }) => method === 'POST' && path === '/git/commits').length, 1);
});

test('PR response-loss cannot admit a moved branch or mismatched base', async () => {
  const fixture = new ProtocolFixture();
  const api = githubClient(fixture.repository, 'token', fixture.fetch);
  const branch = generationBranch('alpha', '3'.repeat(40));
  const expectedHead = '1'.repeat(40);
  fixture.refs.set(branch, '2'.repeat(40));
  const result = await reconcilePrCreate({ api, repository: fixture.repository, baseBranch: 'proposals', baseSha: '3'.repeat(40), branch, name: 'alpha', title: 'update', body: prMarker('alpha'), expectedHead, expectedRegistry: registry() });
  assert.notEqual(result.state, 'CONFIRMED_DONE');
  assert.equal(fixture.calls.filter(({ method, path }) => method === 'POST' && path === '/pulls').length, 1);
});

test('mixed author/committer on PR commits or head is RED', async () => {
  const base = '2'.repeat(40), head = '1'.repeat(40), branch = generationBranch('alpha', base);
  const data = registry();
  const next = applyPin(data, 'alpha', candidate('1.2.4'));
  for (const mixedAt of ['page', 'head']) {
    const api = async (method, path) => {
      if (path.startsWith('/pulls?state=open')) return [{ number: 7, user: { login: BOT }, body: prMarker('alpha'), base: { ref: 'proposals', sha: base }, head: { ref: branch, sha: head, repo: { full_name: 'roccho-dev/windows' } } }];
      if (decodeURIComponent(path) === `/git/ref/heads/${branch}`) return { object: { sha: head } };
      if (path.startsWith('/pulls/7/commits?')) return [{ author: { login: BOT }, committer: { login: mixedAt === 'page' ? 'human' : BOT } }];
      if (path === `/commits/${head}`) return { author: { login: BOT }, committer: { login: mixedAt === 'head' ? 'human' : BOT } };
      if (path.startsWith('/pulls/7/files?')) return [{ filename: 'hosts/profile/releases.json' }];
      if (path.includes(`ref=${head}`)) return { content: Buffer.from(JSON.stringify(next)).toString('base64') };
      if (path.includes(`ref=${base}`)) return { content: Buffer.from(JSON.stringify(data)).toString('base64') };
      if (path.startsWith('/compare/')) return { merge_base_commit: { sha: base } };
      throw new Error(`unexpected ${method} ${path}`);
    };
    await assert.rejects(inspectExistingBotPr({ api, repository: 'roccho-dev/windows', baseBranch: 'proposals', baseSha: base, registry: data, name: 'alpha' }), /foreign/);
  }
});
