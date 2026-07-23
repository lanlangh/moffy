// 再提出の下ごしらえ: (1)空/未送信の reviewSubmission を掃除 (2)バージョン状態とローカライズID報告
// (3)年齢レーティング宣言の現値報告(ソーシャルメディア項目がAPIで設定可能かの判断材料)
// Usage: node asc_prep_resubmit.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs';
import crypto from 'node:crypto';
const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION] = process.argv;
const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path, body) {
  const res = await fetch(BASE + path, { method, headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
const errs = (r) => (r.json?.errors ?? []).map(e => `[${e.code}] ${e.detail}`).join(' | ') || (r.text || '').slice(0, 200);
(async () => {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  console.log('=== reviewSubmissions 掃除 ===');
  const list = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  for (const s of list.json?.data ?? []) {
    const a = s.attributes;
    const items = await api('GET', `/v1/reviewSubmissions/${s.id}/items?limit=30`);
    const n = (items.json?.data ?? []).length;
    console.log(`id=${s.id} state=${a.state} submitted=${a.submittedDate ?? '-'} items=${n}`);
    // 未送信で items が空のもの＝私のテスト残骸。取り消す（UI提出を塞がないため）。
    if (!a.submittedDate && !['COMPLETE', 'CANCELED', 'CANCELING'].includes(a.state) && n === 0) {
      for (const attempt of ['canceled', 'delete']) {
        if (attempt === 'canceled') {
          const c = await api('PATCH', `/v1/reviewSubmissions/${s.id}`, { data: { type: 'reviewSubmissions', id: s.id, attributes: { canceled: true } } });
          console.log(`   → cancel: status=${c.status} ${c.status>=400?errs(c):''}`);
          if (c.status === 200) break;
        } else {
          const d = await api('DELETE', `/v1/reviewSubmissions/${s.id}`);
          console.log(`   → delete: status=${d.status} ${d.status>=400?errs(d):''}`);
        }
      }
    }
  }

  console.log('\n=== バージョン状態 / ローカライズID ===');
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const v = vers.json.data[0];
  console.log(`version ${VERSION} id=${v.id} state=${v.attributes.appStoreState ?? v.attributes.appVersionState}`);
  const locs = await api('GET', `/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=10`);
  for (const l of locs.json?.data ?? []) {
    console.log(`  loc ${l.attributes.locale} id=${l.id} keywords=${(l.attributes.keywords||'').length}字 desc=${(l.attributes.description||'').length}字`);
  }

  console.log('\n=== 年齢レーティング宣言（ソーシャルメディア関連フィールドの有無）===');
  const infos = await api('GET', `/v1/apps/${appId}/appInfos?limit=5`);
  for (const inf of infos.json?.data ?? []) {
    const st = inf.attributes?.appStoreState ?? inf.attributes?.state;
    if (st === 'READY_FOR_DISTRIBUTION') continue;
    const ar = await api('GET', `/v1/appInfos/${inf.id}/ageRatingDeclaration`);
    if (ar.json?.data) {
      console.log(`appInfo ${inf.id} ageRatingDeclaration id=${ar.json.data.id}`);
      const a = ar.json.data.attributes || {};
      // ソーシャルメディア/UGC/チャット関連の現値を全部出す
      for (const k of Object.keys(a)) {
        if (/social|user|chat|messag|web|contact|assur/i.test(k)) console.log(`   ${k} = ${JSON.stringify(a[k])}`);
      }
    }
  }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
