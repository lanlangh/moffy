// App Store Connect: 指定バージョン（例 1.0）に、指定ビルド番号（例 22）を紐付ける。
//
// なぜ必要か: ビルドを TestFlight へ上げただけでは審査に出せない。ASC の
// 「バージョン」に対して「どのビルドを審査に出すか」を明示的に紐付ける必要がある。
// UI でもできるが、CI から再現可能にしておくと取り違え（古いビルドを出す事故）を防げる。
//
// Usage:
//   node asc_attach_build.mjs <p8Path> <keyId> <issuerId> <bundleId> <versionString> <buildNumber>
// 例:
//   node asc_attach_build.mjs key.p8 ABC123 xxxx-yyyy com.example.moffy 1.0 22
//
// 秘密鍵は読み取るだけで出力しない。JWT はローカルで ES256 署名する（依存なし / Node 18+）。
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8_PATH, KEY_ID, ISSUER_ID, BUNDLE_ID, VERSION_STRING, BUILD_NUMBER] = process.argv;
if (!P8_PATH || !KEY_ID || !ISSUER_ID || !BUNDLE_ID || !VERSION_STRING || !BUILD_NUMBER) {
  console.error('args: <p8Path> <keyId> <issuerId> <bundleId> <versionString> <buildNumber>');
  process.exit(2);
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJWT() {
  const pem = fs.readFileSync(P8_PATH, 'utf8');
  const header = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' };
  const signingInput = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
  const signature = crypto.sign('SHA256', Buffer.from(signingInput), {
    key: pem,
    dsaEncoding: 'ieee-p1363',
  });
  return signingInput + '.' + b64url(signature);
}

const BASE = 'https://api.appstoreconnect.apple.com';

async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: 'Bearer ' + makeJWT(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* non-json (204 等) */
  }
  return { status: res.status, json, text };
}

function fail(msg, r) {
  console.error('❌ ' + msg);
  if (r) console.error('   STATUS ' + r.status + ' ' + (r.text || '').slice(0, 600));
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  // 1. アプリを特定
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  if (apps.status !== 200 || !apps.json?.data?.length) fail(`アプリが見つからない (bundleId=${BUNDLE_ID})`, apps);
  const appId = apps.json.data[0].id;
  console.log(`app: id=${appId} bundleId=${BUNDLE_ID}`);

  // 2. 対象バージョン（審査に出す枠）を特定
  const vers = await api(
    'GET',
    `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION_STRING)}&limit=10`,
  );
  if (vers.status !== 200 || !vers.json?.data?.length) fail(`バージョン ${VERSION_STRING} が見つからない`, vers);
  const ver = vers.json.data[0];
  const verId = ver.id;
  const verState = ver.attributes?.appStoreState ?? ver.attributes?.state;
  console.log(`version: id=${verId} ${VERSION_STRING} state=${verState}`);

  // 3. ビルドを特定。TestFlight の処理(processingState)が VALID になるまで待つ。
  //    PROCESSING 中に紐付けようとすると失敗するため、ここで待ってから進む。
  let buildId = null;
  for (let attempt = 1; attempt <= 40; attempt++) {
    const builds = await api(
      'GET',
      `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(BUILD_NUMBER)}&limit=10`,
    );
    if (builds.status !== 200) fail('ビルド一覧の取得に失敗', builds);
    const b = builds.json?.data?.[0];
    if (!b) {
      console.log(`  [${attempt}/40] ビルド ${BUILD_NUMBER} はまだ ASC に現れていない…60秒待つ`);
      await sleep(60_000);
      continue;
    }
    const st = b.attributes?.processingState;
    if (st === 'VALID') {
      buildId = b.id;
      console.log(`build: id=${buildId} number=${BUILD_NUMBER} processingState=VALID`);
      break;
    }
    if (st === 'INVALID' || st === 'FAILED') {
      fail(`ビルド ${BUILD_NUMBER} の処理が ${st} で終わっている（Appleからの拒否メールを確認すること）`);
    }
    console.log(`  [${attempt}/40] processingState=${st}…60秒待つ`);
    await sleep(60_000);
  }
  if (!buildId) fail(`ビルド ${BUILD_NUMBER} が VALID にならなかった（TestFlight の処理待ちが長すぎる）`);

  // 4. 紐付け（冪等: 既に同じビルドなら何もしない）
  const cur = await api('GET', `/v1/appStoreVersions/${verId}/relationships/build`);
  if (cur.status === 200 && cur.json?.data?.id === buildId) {
    console.log(`✅ 既に build ${BUILD_NUMBER} が ${VERSION_STRING} に紐付いている（何もしない）`);
  } else {
    const patch = await api('PATCH', `/v1/appStoreVersions/${verId}/relationships/build`, {
      data: { type: 'builds', id: buildId },
    });
    if (patch.status !== 204 && patch.status !== 200) fail('紐付けに失敗', patch);
    console.log(`✅ build ${BUILD_NUMBER} を ${VERSION_STRING} に紐付けた`);
  }

  // 5. 検証（書いたら読んで確かめる）
  const after = await api('GET', `/v1/appStoreVersions/${verId}/build`);
  const got = after.json?.data?.attributes?.version;
  if (after.status !== 200 || got !== String(BUILD_NUMBER)) {
    fail(`検証失敗: ${VERSION_STRING} に紐付いているのは build=${got ?? '(なし)'}（期待 ${BUILD_NUMBER}）`, after);
  }
  console.log(`✅ 検証OK: ${VERSION_STRING} ← build ${got}`);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
