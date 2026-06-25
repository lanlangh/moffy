// ============================================================================
// RevenueCat Webhook -> Supabase entitlements 反映 (Edge Function / Deno)
// ----------------------------------------------------------------------------
// 設計責任: 開発部署 (engineer)
// 位置づけ: 課金プレミアムの「最終判定 (entitlements) をサーバーを正とする」信頼境界の
//   サーバー側配線。クライアントの「自分は Pro」主張は信じない (docs/IAP_SETUP.md §6)。
//
// データフロー (IAP_SETUP §6-1):
//   [購入/更新/解約/返金]
//     RevenueCat -> Webhook(HTTP POST) -> 本関数
//       -> entitlements を service_role で upsert (is_premium / rc_app_user_id /
//          product_id / expires_at / last_synced_at)
//   ※ RevenueCat の共有シークレット (Authorization) と Supabase の service_role キーは
//     env 経由のサーバー専用秘密 (ハードコード禁止 / クライアントへは絶対に出さない)。
//
// 必要な環境変数 (すべてサーバー専用 / Supabase Function Secrets で設定):
//   * REVENUECAT_WEBHOOK_AUTH    … RevenueCat ダッシュボードの Webhook に設定する
//                                   Authorization ヘッダの共有シークレット (任意の長い文字列)。
//   * SUPABASE_URL               … プロジェクト URL (デプロイ時に自動付与されるが明示)。
//   * SUPABASE_SERVICE_ROLE_KEY  … service_role キー (RLS をバイパスして entitlements を書く)。
//   * REVIEWER_APP_USER_IDS      … (任意) 審査用に is_premium=true 扱いにする app_user_id の
//                                   カンマ区切りリスト (IAP_SETUP §6-4)。
//
// デプロイ:
//   supabase functions deploy revenuecat-webhook --no-verify-jwt
//   (RevenueCat は Supabase の JWT を持たないため --no-verify-jwt。認証は本関数内で
//    REVENUECAT_WEBHOOK_AUTH の定数時間比較により行う。)
//
// 注意 (Flutter CI の検査対象外):
//   本ファイルは Deno/TypeScript で、Flutter の dart analyze / flutter test では検証されない。
//   型・構文は慎重に記述し、最終検証は「supabase functions deploy 時」と実 Webhook 送信で行う。
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

// --- RevenueCat Webhook ペイロードの最小型 (必要フィールドのみ) ---
// 公式仕様: https://www.revenuecat.com/docs/webhooks
interface RcEntitlementInfo {
  expires_date?: string | null;
}

interface RcEvent {
  type?: string;
  app_user_id?: string;
  // 過去にログインに使われた別名 (匿名 -> logIn 前後で別 ID になりうる)。
  aliases?: string[];
  original_app_user_id?: string;
  product_id?: string;
  // entitlement 識別子の配列 (このイベントが影響する entitlement)。
  entitlement_ids?: string[] | null;
  // 失効予定時刻 (ms epoch)。RENEWAL/PURCHASE では未来、EXPIRATION 等では過去/現在。
  expiration_at_ms?: number | null;
  // イベント発生時刻 (ms epoch)。冪等判定 (後勝ち防止) に使う。
  event_timestamp_ms?: number | null;
}

interface RcWebhookBody {
  event?: RcEvent;
  api_version?: string;
}

// entitlement `premium` を有効化する (プレミアム継続) イベント種別。
const ACTIVATING_EVENTS = new Set<string>([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_EXTENDED",
]);

// entitlement `premium` を失効させる (プレミアム剥奪) イベント種別。
const DEACTIVATING_EVENTS = new Set<string>([
  "EXPIRATION",
  "BILLING_ISSUE",
]);

// CANCELLATION は「自動更新の停止」であり、期限までは premium を維持する (即時剥奪しない)。
// その判定は expires_at が未来かどうかで行うため、種別の集合には入れない。

// SSOT: entitlement 識別子はクライアント (pricing.dart RevenueCatIds.entitlementPremium) と
//   一致させる。Edge Function は pricing.dart を import できないため、ここで定数を持つ
//   (値が変わる頻度は極めて低い。変更時は両側を直す)。
const ENTITLEMENT_PREMIUM = "premium";

// UUID v4 形式の検査 (app_user_id が Supabase user_id かの一次判定)。
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * 定数時間で2つの文字列を比較する (タイミング攻撃対策)。
 * 長さが違う場合でも早期 return せず、固定長のダミー比較を行って差を漏らさない。
 */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  // 長さ不一致でも比較長は ab に固定し、長さの差自体は最後の OR で反映する。
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < ab.length; i++) {
    // bb が短い場合は 0 と XOR (範囲外アクセスを避けつつ差分を蓄積)。
    diff |= ab[i] ^ (i < bb.length ? bb[i] : 0);
  }
  return diff === 0;
}

/** JSON レスポンスの共通ヘルパ。 */
function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** 本番ログを汚さない最小ログ (機密・PII は出さない / event type と user の有無のみ)。 */
function logInfo(message: string, meta?: Record<string, unknown>): void {
  // Edge Function のログは Supabase 側に閉じる。app_user_id 等の生値は出さない。
  console.log(JSON.stringify({ level: "info", message, ...(meta ?? {}) }));
}

function logError(message: string, meta?: Record<string, unknown>): void {
  console.error(JSON.stringify({ level: "error", message, ...(meta ?? {}) }));
}

/** カンマ区切り env をトリム済み集合に変換する。 */
function parseReviewerIds(raw: string | undefined): Set<string> {
  if (!raw) return new Set();
  return new Set(
    raw
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0),
  );
}

Deno.serve(async (req: Request): Promise<Response> => {
  // --- メソッド検証 (Webhook は POST のみ) ---
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  // --- env 取得 (秘密はすべて env 経由 / ハードコード禁止) ---
  const expectedAuth = Deno.env.get("REVENUECAT_WEBHOOK_AUTH");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!expectedAuth || !supabaseUrl || !serviceRoleKey) {
    // 設定不備はサーバー側の問題。RevenueCat に再送させるため 500 を返す。
    logError("missing_env", {
      hasAuth: Boolean(expectedAuth),
      hasUrl: Boolean(supabaseUrl),
      hasKey: Boolean(serviceRoleKey),
    });
    return json(500, { error: "server_misconfigured" });
  }

  // --- 認証 (共有シークレットの定数時間比較) ---
  // RevenueCat ダッシュボードの Webhook に設定した Authorization ヘッダと一致しなければ 401。
  const providedAuth = req.headers.get("authorization") ?? "";
  if (!timingSafeEqual(providedAuth, expectedAuth)) {
    logError("unauthorized");
    return json(401, { error: "unauthorized" });
  }

  // --- ボディのパース ---
  let body: RcWebhookBody;
  try {
    body = (await req.json()) as RcWebhookBody;
  } catch (_e) {
    return json(400, { error: "invalid_json" });
  }

  const event = body.event;
  if (!event || typeof event !== "object") {
    return json(400, { error: "missing_event" });
  }

  const eventType = (event.type ?? "").toUpperCase();
  const appUserId = event.app_user_id ?? "";

  // app_user_id が空のイベント (テストイベント等) は受理だけして握る (200)。
  if (appUserId.length === 0) {
    logInfo("event_without_app_user_id", { eventType });
    return json(200, { ok: true, skipped: "no_app_user_id" });
  }

  const reviewerIds = parseReviewerIds(Deno.env.get("REVIEWER_APP_USER_IDS"));
  const isReviewer = reviewerIds.has(appUserId);

  // --- premium 有効性の判定 ---
  // 1) このイベントが entitlement `premium` に関係するか (entitlement_ids にあるか、
  //    もしくは情報が無い古いペイロードは種別だけで判定)。
  // 2) 失効時刻 (expiration_at_ms) が未来か。
  const entitlementIds = event.entitlement_ids ?? [];
  const touchesPremium = entitlementIds.length === 0 ||
    entitlementIds.includes(ENTITLEMENT_PREMIUM);

  const nowMs = Date.now();
  const expirationMs = typeof event.expiration_at_ms === "number"
    ? event.expiration_at_ms
    : null;
  // 失効時刻が未来 (または不明=null かつ有効化イベント) なら有効期間内とみなす。
  const notExpired = expirationMs === null ? true : expirationMs > nowMs;

  let isPremium: boolean;
  if (isReviewer) {
    // レビュアーバイパス (§6-4): 審査用アカウントは常に premium 扱い。
    isPremium = true;
  } else if (DEACTIVATING_EVENTS.has(eventType)) {
    isPremium = false;
  } else if (ACTIVATING_EVENTS.has(eventType)) {
    isPremium = touchesPremium && notExpired;
  } else if (eventType === "CANCELLATION") {
    // 解約 (自動更新停止)。期限までは premium 維持 (期限が未来なら true)。
    isPremium = touchesPremium && notExpired;
  } else {
    // TRANSFER / SUBSCRIBER_ALIAS / TEST / 未知種別: 失効時刻ベースで素直に判定する
    // (情報があれば反映、無ければ現状維持寄り = 期限未来なら true)。
    isPremium = touchesPremium && notExpired;
  }

  const expiresAtIso = expirationMs === null
    ? null
    : new Date(expirationMs).toISOString();

  // イベント発生時刻 (冪等の後勝ち防止に使う)。無い場合は受信時刻で代替。
  const eventTsMs = typeof event.event_timestamp_ms === "number"
    ? event.event_timestamp_ms
    : nowMs;
  const eventTsIso = new Date(eventTsMs).toISOString();

  const client = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // --- app_user_id が Supabase user_id (UUID) でない場合の保護 (§7) ---
  // 匿名 (logIn 前) のイベントだと app_user_id が RevenueCat 匿名 ID ($RCAnonymousID:...)
  // のことがある。その場合 entitlements の PK (user_id uuid) には使えないため、
  // クラッシュさせず受理だけする (後で logIn 後のイベントで是正される)。
  if (!UUID_RE.test(appUserId)) {
    logInfo("non_uuid_app_user_id", { eventType });
    return json(200, { ok: true, skipped: "non_uuid_app_user_id" });
  }

  try {
    // --- 冪等: 既存行の last_synced_at と比較し、古いイベントは反映しない (§4) ---
    // RevenueCat はイベントを再送・順序前後しうる。event_timestamp が既存より古ければ
    // 状態を巻き戻さない (後勝ちにしない)。同値は再適用しても結果同一なので許容。
    const { data: existing, error: selErr } = await client
      .from("entitlements")
      .select("last_synced_at")
      .eq("user_id", appUserId)
      .maybeSingle();

    if (selErr) {
      // auth.users に無い user_id への参照などで FK 前に select は通る想定。
      // select 失敗はサーバー側障害として 500 (RevenueCat に再送させる)。
      logError("select_failed", { code: selErr.code });
      return json(500, { error: "select_failed" });
    }

    if (existing?.last_synced_at) {
      const existingMs = Date.parse(existing.last_synced_at as string);
      if (!Number.isNaN(existingMs) && existingMs > eventTsMs) {
        // 既存の方が新しい = 古いイベントの再送。状態を壊さないため反映しない。
        logInfo("stale_event_ignored", { eventType });
        return json(200, { ok: true, skipped: "stale_event" });
      }
    }

    // --- entitlements upsert (service_role が RLS をバイパス) ---
    // last_synced_at にはイベント発生時刻を入れる (受信時刻ではなく) ことで、
    // 次回以降の冪等比較が「イベントの新しさ」を正しく表すようにする。
    const { error: upsertErr } = await client
      .from("entitlements")
      .upsert(
        {
          user_id: appUserId,
          is_premium: isPremium,
          rc_app_user_id: appUserId,
          product_id: event.product_id ?? null,
          expires_at: expiresAtIso,
          last_synced_at: eventTsIso,
        },
        { onConflict: "user_id" },
      );

    if (upsertErr) {
      // FK 違反 (auth.users に存在しない user_id) 等。23503 = foreign_key_violation。
      if (upsertErr.code === "23503") {
        // user は将来 auth に現れる可能性 (是正余地)。再送不要なので 200 で握る。
        logInfo("user_not_in_auth", { eventType });
        return json(200, { ok: true, skipped: "user_not_found" });
      }
      logError("upsert_failed", { code: upsertErr.code });
      return json(500, { error: "upsert_failed" });
    }

    logInfo("entitlement_synced", { eventType, isPremium, isReviewer });
    return json(200, { ok: true });
  } catch (e) {
    // 想定外例外でも entitlements を壊さない。500 で RevenueCat に再送を促す。
    logError("unhandled_exception", {
      error: e instanceof Error ? e.message : "unknown",
    });
    return json(500, { error: "internal_error" });
  }
});
