#!/usr/bin/env node
// google-play-mcp — Google Play Console (Android Publisher API v3) を操作する stdio MCP サーバ
//
// 認証: サービスアカウント JSON を「ファイルパス」で受け取り（中身は env/ソースに書かない）、
//       google-auth-library の GoogleAuth で OAuth2 アクセストークンを取得する。
//   - GOOGLE_PLAY_SA_JSON_PATH : サービスアカウント JSON の絶対パス（最優先）
//   - GOOGLE_APPLICATION_CREDENTIALS : 上が無い場合の補助（GoogleAuth 標準の環境変数）
//   - GOOGLE_PLAY_PACKAGE_NAME : 既定 packageName（任意。各ツールで省略時に使用）
//
// スコープ: https://www.googleapis.com/auth/androidpublisher
// ベース URL: https://androidpublisher.googleapis.com/androidpublisher/v3
//
// ⚠️ 注意: 本実装は実 Play API に接続して検証できない環境で作成している。
//          リクエスト/レスポンス形状は Android Publisher API v3 公式仕様に合わせているが、
//          「推測」と明記した箇所は初回接続時に要確認。

import { existsSync, readFileSync } from 'node:fs';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { GoogleAuth } from 'google-auth-library';
import { z } from 'zod';
import { zodToJsonSchema } from 'zod-to-json-schema';

const API_BASE =
  'https://androidpublisher.googleapis.com/androidpublisher/v3';
const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

// ---------------------------------------------------------------------------
// 認証
// ---------------------------------------------------------------------------

let _authClientPromise = null;

/**
 * サービスアカウント JSON のパスを解決する。
 * GOOGLE_PLAY_SA_JSON_PATH を最優先、無ければ GOOGLE_APPLICATION_CREDENTIALS。
 * いずれも「パス」のみ。JSON 本体を env に直書きさせない設計。
 */
function resolveCredentialsPath() {
  const primary = process.env.GOOGLE_PLAY_SA_JSON_PATH;
  const fallback = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  const candidate = (primary && primary.trim()) || (fallback && fallback.trim());

  if (!candidate) {
    throw new Error(
      'サービスアカウント JSON のパスが未設定です。' +
        '.claude/settings.local.json の env に GOOGLE_PLAY_SA_JSON_PATH ' +
        '（サービスアカウント JSON の絶対パス）を設定してください。' +
        '（補助として GOOGLE_APPLICATION_CREDENTIALS も使用可）'
    );
  }
  if (!existsSync(candidate)) {
    throw new Error(
      `サービスアカウント JSON が見つかりません: ${candidate} ` +
        '（GOOGLE_PLAY_SA_JSON_PATH の絶対パスを確認してください）'
    );
  }
  // パスの妥当性（JSON として読めるか）を早期に検証し、診断しやすくする。
  try {
    JSON.parse(readFileSync(candidate, 'utf8'));
  } catch (e) {
    throw new Error(
      `サービスアカウント JSON のパースに失敗しました: ${candidate} ` +
        `(${e.message})。正しいサービスアカウント鍵 JSON か確認してください。`
    );
  }
  return candidate;
}

/**
 * GoogleAuth のクライアント（自動でアクセストークンを発行/更新）を一度だけ生成する。
 */
function getAuth() {
  if (!_authClientPromise) {
    _authClientPromise = (async () => {
      const keyFile = resolveCredentialsPath();
      const auth = new GoogleAuth({ keyFile, scopes: [SCOPE] });
      // getClient() は JWT クライアントを返す。getAccessToken() でトークンを取得できる。
      return auth.getClient();
    })().catch((err) => {
      // 失敗時は次回再試行できるようキャッシュをクリア
      _authClientPromise = null;
      throw err;
    });
  }
  return _authClientPromise;
}

async function getAccessToken() {
  const client = await getAuth();
  const { token } = await client.getAccessToken();
  if (!token) {
    throw new Error(
      'アクセストークンの取得に失敗しました。サービスアカウントの権限/鍵を確認してください。'
    );
  }
  return token;
}

// ---------------------------------------------------------------------------
// 共通リクエストヘルパ
// ---------------------------------------------------------------------------

function buildQuery(query) {
  if (!query) return '';
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === '') continue;
    params.append(k, String(v));
  }
  const s = params.toString();
  return s ? `?${s}` : '';
}

/**
 * Android Publisher API への共通リクエスト。
 * トークン付与・JSON パース・エラー診断（Google API の error.message/status/詳細を読める形）を行う。
 *
 * @param {string} method  HTTP メソッド
 * @param {string} path    API_BASE 以降のパス（先頭スラッシュ込み）
 * @param {object} [opts]
 * @param {object} [opts.query] クエリパラメータ
 * @param {object} [opts.body]  JSON ボディ
 */
async function gpcRequest(method, path, { query, body } = {}) {
  const token = await getAccessToken();
  const url = `${API_BASE}${path}${buildQuery(query)}`;

  const headers = { Authorization: `Bearer ${token}` };
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }

  let res;
  try {
    res = await fetch(url, { method, headers, body: payload });
  } catch (e) {
    // ネットワーク層のエラー（DNS/接続不可等）
    throw new Error(`Google Play API への接続に失敗しました (${method} ${url}): ${e.message}`);
  }

  const text = await res.text();
  let parsed;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text; // JSON でない応答（HTML エラーページ等）はそのまま保持
    }
  }

  if (!res.ok) {
    // Google API の標準エラー形状: { error: { code, message, status, details: [...] } }
    const apiErr = parsed && typeof parsed === 'object' ? parsed.error : undefined;
    const code = apiErr?.code ?? res.status;
    const status = apiErr?.status ?? res.statusText;
    const message = apiErr?.message ?? (typeof parsed === 'string' ? parsed : 'Unknown error');
    let detailStr = '';
    if (apiErr?.details) {
      try {
        detailStr = `\n詳細: ${JSON.stringify(apiErr.details)}`;
      } catch {
        /* noop */
      }
    }
    throw new Error(
      `Google Play API エラー [${code} ${status}] ${method} ${path}: ${message}${detailStr}`
    );
  }

  return parsed ?? {};
}

/** 既定 packageName を適用 */
function resolvePackageName(arg) {
  const pkg = (arg && arg.trim()) || (process.env.GOOGLE_PLAY_PACKAGE_NAME || '').trim();
  if (!pkg) {
    throw new Error(
      'packageName が未指定です。引数で渡すか、env GOOGLE_PLAY_PACKAGE_NAME に既定値を設定してください。'
    );
  }
  return pkg;
}

function ok(data) {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
}

// ---------------------------------------------------------------------------
// ツール定義
//   各ツール: { schema(zod), description, handler }
//   入力スキーマは zod で定義し、ListTools 時に JSON Schema へ変換して公開する。
// ---------------------------------------------------------------------------

const packageNameField = z
  .string()
  .optional()
  .describe('対象アプリの packageName（省略時は env GOOGLE_PLAY_PACKAGE_NAME を使用）');

const tools = {
  // -- 定期購入（Subscriptions / monetization v3） ----------------------------
  gpc_list_subscriptions: {
    description:
      '定期購入（サブスク）一覧を取得する。対応: GET /applications/{packageName}/subscriptions',
    schema: z.object({
      packageName: packageNameField,
      pageSize: z.number().int().positive().optional().describe('1ページ件数（任意）'),
      pageToken: z.string().optional().describe('ページネーション用トークン（任意）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      const data = await gpcRequest('GET', `/applications/${pkg}/subscriptions`, {
        query: { pageSize: args.pageSize, pageToken: args.pageToken },
      });
      return ok(data);
    },
  },

  gpc_get_subscription: {
    description:
      '定期購入を1件取得する。対応: GET /applications/{packageName}/subscriptions/{productId}',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('定期購入の productId（例: moffy_premium_monthly）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      const data = await gpcRequest(
        'GET',
        `/applications/${pkg}/subscriptions/${encodeURIComponent(args.productId)}`
      );
      return ok(data);
    },
  },

  gpc_create_subscription: {
    description:
      '【破壊的操作】Google Play に実際に定期購入（サブスク）商品を作成する。' +
      '対応: POST /applications/{packageName}/subscriptions?productId={productId} ' +
      '（body=Subscription リソース）。productId が既存と重複する場合 Google が返すエラーをそのまま伝播する。',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('作成する定期購入の productId（一意。例: moffy_premium_monthly）'),
      // Subscription リソース。listings / basePlans 等をそのまま受け取る。
      // 公式: SubscriptionListing { languageCode, title, benefits[], description }
      listings: z
        .array(
          z.object({
            languageCode: z.string().describe('BCP-47 言語コード（例: ja-JP）'),
            title: z.string().describe('ストア表示タイトル'),
            description: z.string().optional(),
            benefits: z.array(z.string()).optional().describe('特典の箇条書き（任意）'),
          })
        )
        .describe('ストア表示情報。最低1件必要。'),
      basePlans: z
        .array(z.record(z.any()))
        .optional()
        .describe(
          '基本プラン（BasePlan）の配列。作成時に同梱可。' +
            '例: [{ basePlanId, autoRenewingBasePlanType:{ billingPeriodDuration:"P1M", ... } }]'
        ),
      // regionsVersion はクエリパラメータ（body フィールドではない）。create に必須
      // （未指定だと 400 "Regions Version must be specified" / 実API検証 2026-06-26）。
      regionsVersion: z
        .string()
        .optional()
        .describe('利用可能地域のバージョン（クエリ regionsVersion.version）。既定 "2022/01"'),
      // 上記以外の Subscription フィールド（taxAndComplianceSettings 等）を透過的に渡す逃げ道。
      extra: z
        .record(z.any())
        .optional()
        .describe('Subscription リソースの追加フィールド（透過渡し。任意）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      // Subscription リソース本体を組み立て。productId はパス/クエリと body 両方に含めるのが v3 仕様。
      const body = {
        packageName: pkg,
        productId: args.productId,
        listings: args.listings,
        ...(args.basePlans ? { basePlans: args.basePlans } : {}),
        ...(args.extra || {}),
      };
      const data = await gpcRequest('POST', `/applications/${pkg}/subscriptions`, {
        // regionsVersion.version はクエリ必須（body だと "Unknown name" / 実API検証済み）。
        query: {
          productId: args.productId,
          'regionsVersion.version': args.regionsVersion || '2022/01',
        },
        body,
      });
      return ok(data);
    },
  },

  gpc_patch_subscription: {
    description:
      '【破壊的操作】Google Play 上の既存定期購入を更新する。' +
      '対応: PATCH /applications/{packageName}/subscriptions/{productId}?updateMask=... ' +
      'updateMask に更新対象フィールド（カンマ区切り）を必ず指定する。',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('更新対象の productId'),
      updateMask: z
        .string()
        .describe('更新するフィールドパス（カンマ区切り。例: listings,taxAndComplianceSettings）'),
      subscription: z
        .record(z.any())
        .describe('更新後の Subscription リソース（部分。updateMask で指定したフィールドを含む）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      // body には productId/packageName を含めるのが安全（v3 は body の resource を期待）。
      // パス識別子は固定キーを後置きして、subscription 側の同名キーで上書きされないようにする（QA L1）。
      const body = {
        ...args.subscription,
        packageName: pkg,
        productId: args.productId,
      };
      const data = await gpcRequest(
        'PATCH',
        `/applications/${pkg}/subscriptions/${encodeURIComponent(args.productId)}`,
        { query: { updateMask: args.updateMask }, body }
      );
      return ok(data);
    },
  },

  gpc_activate_base_plan: {
    description:
      '【破壊的操作】基本プラン（BasePlan）を有効化（公開）する。' +
      '対応: POST /applications/{packageName}/subscriptions/{productId}/basePlans/{basePlanId}:activate',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('定期購入の productId'),
      basePlanId: z.string().describe('有効化する基本プランの basePlanId'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      // :activate は body 内に packageName/productId/basePlanId を要求する（推測: 公式 ActivateBasePlanRequest）。
      const body = {
        packageName: pkg,
        productId: args.productId,
        basePlanId: args.basePlanId,
      };
      const data = await gpcRequest(
        'POST',
        `/applications/${pkg}/subscriptions/${encodeURIComponent(
          args.productId
        )}/basePlans/${encodeURIComponent(args.basePlanId)}:activate`,
        { body }
      );
      return ok(data);
    },
  },

  gpc_create_offer: {
    description:
      '【破壊的操作】Google Play に基本プランのオファー（無料トライアル等）を実際に作成する。' +
      '対応: POST /applications/{packageName}/subscriptions/{productId}/basePlans/{basePlanId}/offers?offerId={offerId} ' +
      '（body=SubscriptionOffer リソース: phases[], regionalConfigs[] 等）',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('定期購入の productId'),
      basePlanId: z.string().describe('オファーを紐づける basePlanId'),
      offerId: z.string().describe('作成するオファーの offerId（一意。例: freetrial-7d）'),
      phases: z
        .array(z.record(z.any()))
        .optional()
        .describe(
          'オファーのフェーズ配列。無料トライアルは ' +
            '{ duration:"P7D", recurrenceCount:1, regionalConfigs:[{ regionCode, free:{} }] } など。'
        ),
      regionalConfigs: z
        .array(z.record(z.any()))
        .optional()
        .describe('オファーの地域別設定 OfferRegionalConfig[]（例: [{ regionCode:"JP", newSubscriberAvailability:true }]）'),
      extra: z
        .record(z.any())
        .optional()
        .describe('SubscriptionOffer の追加フィールド（offerTags, targeting 等。透過渡し。任意）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      const body = {
        packageName: pkg,
        productId: args.productId,
        basePlanId: args.basePlanId,
        offerId: args.offerId,
        ...(args.phases ? { phases: args.phases } : {}),
        ...(args.regionalConfigs ? { regionalConfigs: args.regionalConfigs } : {}),
        ...(args.extra || {}),
      };
      const data = await gpcRequest(
        'POST',
        `/applications/${pkg}/subscriptions/${encodeURIComponent(
          args.productId
        )}/basePlans/${encodeURIComponent(args.basePlanId)}/offers`,
        { query: { offerId: args.offerId }, body }
      );
      return ok(data);
    },
  },

  gpc_activate_offer: {
    description:
      '【破壊的操作】サブスクのオファーを有効化（公開）する。' +
      '対応: POST /applications/{packageName}/subscriptions/{productId}/basePlans/{basePlanId}/offers/{offerId}:activate',
    schema: z.object({
      packageName: packageNameField,
      productId: z.string().describe('定期購入の productId'),
      basePlanId: z.string().describe('basePlanId'),
      offerId: z.string().describe('有効化する offerId'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      // :activate の body（推測: 公式 ActivateSubscriptionOfferRequest）
      const body = {
        packageName: pkg,
        productId: args.productId,
        basePlanId: args.basePlanId,
        offerId: args.offerId,
      };
      const data = await gpcRequest(
        'POST',
        `/applications/${pkg}/subscriptions/${encodeURIComponent(
          args.productId
        )}/basePlans/${encodeURIComponent(args.basePlanId)}/offers/${encodeURIComponent(
          args.offerId
        )}:activate`,
        { body }
      );
      return ok(data);
    },
  },

  // -- 旧形式の商品（In-app products） ---------------------------------------
  gpc_list_inappproducts: {
    description:
      'アプリ内商品（管理対象/旧サブスク含む inappproducts）一覧を取得する。' +
      '対応: GET /applications/{packageName}/inappproducts',
    schema: z.object({
      packageName: packageNameField,
      maxResults: z.number().int().positive().optional().describe('最大件数（任意）'),
      startIndex: z.number().int().nonnegative().optional().describe('開始インデックス（任意）'),
      token: z.string().optional().describe('ページネーショントークン（任意）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      const data = await gpcRequest('GET', `/applications/${pkg}/inappproducts`, {
        query: {
          maxResults: args.maxResults,
          startIndex: args.startIndex,
          token: args.token,
        },
      });
      return ok(data);
    },
  },

  // -- レビュー --------------------------------------------------------------
  gpc_list_reviews: {
    description:
      'ユーザーレビュー一覧を取得する。対応: GET /applications/{packageName}/reviews',
    schema: z.object({
      packageName: packageNameField,
      maxResults: z.number().int().positive().optional().describe('最大件数（任意）'),
      startIndex: z.number().int().nonnegative().optional().describe('開始インデックス（任意）'),
      token: z.string().optional().describe('ページネーショントークン（任意）'),
      translationLanguage: z
        .string()
        .optional()
        .describe('レビュー本文の翻訳先言語（任意。例: ja）'),
    }),
    async handler(args) {
      const pkg = resolvePackageName(args.packageName);
      const data = await gpcRequest('GET', `/applications/${pkg}/reviews`, {
        query: {
          maxResults: args.maxResults,
          startIndex: args.startIndex,
          token: args.token,
          translationLanguage: args.translationLanguage,
        },
      });
      return ok(data);
    },
  },
};

// ---------------------------------------------------------------------------
// MCP サーバ（低レベル Server + setRequestHandler。asc-mcp と同方式）
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'google-play-mcp', version: '0.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: Object.entries(tools).map(([name, def]) => ({
    name,
    description: def.description,
    inputSchema: zodToJsonSchema(def.schema, { target: 'jsonSchema7' }),
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: rawArgs } = request.params;
  const def = tools[name];
  if (!def) {
    return {
      isError: true,
      content: [{ type: 'text', text: `未知のツール: ${name}` }],
    };
  }
  // 入力検証（zod）。失敗時は分かりやすいエラーを返す。
  const parsed = def.schema.safeParse(rawArgs ?? {});
  if (!parsed.success) {
    return {
      isError: true,
      content: [
        {
          type: 'text',
          text: `入力エラー (${name}): ${parsed.error.issues
            .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
            .join('; ')}`,
        },
      ],
    };
  }
  try {
    return await def.handler(parsed.data);
  } catch (e) {
    return { isError: true, content: [{ type: 'text', text: e.message }] };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stdio MCP は stdout を JSON-RPC に使うため、ログは stderr のみ。
  console.error('google-play-mcp ready (Android Publisher API v3).');
}

main().catch((err) => {
  console.error('google-play-mcp fatal:', err);
  process.exit(1);
});
