import fs from 'node:fs'; import crypto from 'node:crypto';
const [,,P8,KEY_ID,ISSUER,BUNDLE_ID,VERSION,SUB_ID]=process.argv;
const b64=(b)=>Buffer.from(b).toString('base64').replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_');
function jwt(){const pem=fs.readFileSync(P8,'utf8');const n=Math.floor(Date.now()/1000);const si=b64(JSON.stringify({alg:'ES256',kid:KEY_ID,typ:'JWT'}))+'.'+b64(JSON.stringify({iss:ISSUER,iat:n,exp:n+600,aud:'appstoreconnect-v1'}));return si+'.'+b64(crypto.sign('SHA256',Buffer.from(si),{key:pem,dsaEncoding:'ieee-p1363'}));}
const B='https://api.appstoreconnect.apple.com';
async function api(m,p,body){const r=await fetch(B+p,{method:m,headers:{Authorization:'Bearer '+jwt(),'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const t=await r.text();let j=null;try{j=t?JSON.parse(t):null}catch{}return{status:r.status,json:j,text:t};}
const errs=(r)=>(r.json?.errors??[]).map(e=>`[${e.code}] ${e.title}: ${e.detail}`).join(' | ')||(r.text||'').slice(0,300);
(async()=>{
  const apps=await api('GET',`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);const appId=apps.json.data[0].id;
  const vers=await api('GET',`/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);const verId=vers.json.data[0].id;
  console.log('version state=',vers.json.data[0].attributes.appStoreState);
  console.log('=== 試し1: 既存submission '+SUB_ID+' に本体を追加 ===');
  const a1=await api('POST','/v1/reviewSubmissionItems',{data:{type:'reviewSubmissionItems',relationships:{reviewSubmission:{data:{type:'reviewSubmissions',id:SUB_ID}},appStoreVersion:{data:{type:'appStoreVersions',id:verId}}}}});
  console.log('  status='+a1.status+' '+(a1.status===201?'✅追加OK':('❌ '+errs(a1))));
  if(a1.status===201){console.log('→ 既存submissionに戻せた。UIで「App Reviewに再提出」可。');return;}
  console.log('=== 試し2: 新規submissionを作って本体を追加 ===');
  const c=await api('POST','/v1/reviewSubmissions',{data:{type:'reviewSubmissions',attributes:{platform:'IOS'},relationships:{app:{data:{type:'apps',id:appId}}}}});
  if(c.status!==201){console.log('  新規作成失敗: '+errs(c));return;}
  const nid=c.json.data.id;console.log('  新規submission id='+nid);
  const a2=await api('POST','/v1/reviewSubmissionItems',{data:{type:'reviewSubmissionItems',relationships:{reviewSubmission:{data:{type:'reviewSubmissions',id:nid}},appStoreVersion:{data:{type:'appStoreVersions',id:verId}}}}});
  console.log('  本体追加 status='+a2.status+' '+(a2.status===201?'✅':('❌ '+errs(a2))));
  console.log('→ 新規submission '+nid+' に本体あり。サブスクをここへ移す必要がある。');
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
