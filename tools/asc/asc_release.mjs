// 承認済み(PENDING_DEVELOPER_RELEASE)のバージョンを公開する。
// Usage: node asc_release.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs'; import crypto from 'node:crypto';
const [,,P8,KEY_ID,ISSUER,BUNDLE_ID,VERSION]=process.argv;
const b64=(b)=>Buffer.from(b).toString('base64').replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_');
function jwt(){const pem=fs.readFileSync(P8,'utf8');const n=Math.floor(Date.now()/1000);const si=b64(JSON.stringify({alg:'ES256',kid:KEY_ID,typ:'JWT'}))+'.'+b64(JSON.stringify({iss:ISSUER,iat:n,exp:n+600,aud:'appstoreconnect-v1'}));return si+'.'+b64(crypto.sign('SHA256',Buffer.from(si),{key:pem,dsaEncoding:'ieee-p1363'}));}
const B='https://api.appstoreconnect.apple.com';
async function api(m,p,body){const r=await fetch(B+p,{method:m,headers:{Authorization:'Bearer '+jwt(),'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const t=await r.text();let j=null;try{j=t?JSON.parse(t):null}catch{}return{status:r.status,json:j,text:t};}
const errs=(r)=>(r.json?.errors??[]).map(e=>`[${e.code}] ${e.title}: ${e.detail}`).join(' | ')||(r.text||'').slice(0,300);
(async()=>{
  const apps=await api('GET',`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);const appId=apps.json.data[0].id;
  const vers=await api('GET',`/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);const v=vers.json.data[0];
  const st=v.attributes.appStoreState??v.attributes.appVersionState;
  console.log(`version ${VERSION} state=${st}`);
  if(st==='READY_FOR_SALE'||st==='READY_FOR_DISTRIBUTION'){console.log('✅ 既に公開済み');return;}
  if(st!=='PENDING_DEVELOPER_RELEASE'){console.error('❌ リリースできる状態でない(PENDING_DEVELOPER_RELEASEでない)');process.exit(1);}
  const rel=await api('POST','/v1/appStoreVersionReleaseRequests',{data:{type:'appStoreVersionReleaseRequests',relationships:{appStoreVersion:{data:{type:'appStoreVersions',id:v.id}}}}});
  if(rel.status!==201){console.error('❌ リリース要求に失敗: '+errs(rel));process.exit(1);}
  console.log('✅ リリース要求を送信しました');
  // 状態確認
  const v2=await api('GET',`/v1/appStoreVersions/${v.id}`);
  console.log(`→ 現在の state=${v2.json?.data?.attributes?.appStoreState??v2.json?.data?.attributes?.appVersionState}`);
  console.log('app id='+appId);
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
