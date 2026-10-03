import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SERVICE_KEY = Deno.env.get('SB_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
export const admin: SupabaseClient = createClient(Deno.env.get('SUPABASE_URL')!, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

const SAFE_DB_ERRORS = /^(ADDRESS_NOT_FOUND|EMPTY_CART|BAD_QUANTITY|ITEM_UNAVAILABLE|OUT_OF_STOCK|COUPON_INVALID|COD_LIMIT|PAYMENT_METHOD_UNAVAILABLE)/;

export function handle(fn: (req: Request) => Promise<unknown>) {
  return async (req: Request) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
    try {
      return json(await fn(req));
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      const msg = (e as { message?: string })?.message ?? '';
      if (SAFE_DB_ERRORS.test(msg)) return json({ error: msg }, 400);
      console.error(e);
      return json({ error: 'Server error' }, 500);
    }
  };
}

export type Caller = {
  id: string; role: 'customer' | 'admin' | 'delivery_partner'; is_active: boolean;
  is_verified: boolean; full_name: string | null; mobile_number: string | null;
};

// Validates the caller's session token and loads their profile. Disabled users
// (or delivery partners whose parent admin is disabled) are rejected here.
export async function authUser(req: Request, opts: { roles: Caller['role'][]; requireVerified?: boolean }): Promise<Caller> {
  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!jwt) throw new HttpError(401, 'Not signed in');
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data.user) throw new HttpError(401, 'Session expired. Sign in again.');
  const { data: p } = await admin.from('profiles')
    .select('id, role, is_active, is_verified, full_name, mobile_number, created_by_admin_id')
    .eq('id', data.user.id).single();
  if (!p || !p.is_active) throw new HttpError(403, 'Account disabled');
  if (!opts.roles.includes(p.role)) throw new HttpError(403, 'Not allowed');
  if (p.role === 'delivery_partner') {
    const { data: parent } = await admin.from('profiles').select('role, is_active').eq('id', p.created_by_admin_id).maybeSingle();
    if (!parent || parent.role !== 'admin' || !parent.is_active) throw new HttpError(403, 'Account disabled');
  }
  if (opts.requireVerified && !p.is_verified) throw new HttpError(403, 'Verify your mobile number first');
  return p as Caller;
}

// ---- OTP helpers -----------------------------------------------------------
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
export async function hmac(value: string): Promise<string> {
  const pepper = Deno.env.get('OTP_PEPPER');
  if (!pepper) throw new Error('OTP_PEPPER secret is not set');
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(pepper), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value)));
}
export function randomCode(digits = 6): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 10 ** digits;
  return String(n).padStart(digits, '0');
}
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// ---- Fonnte (WhatsApp) -----------------------------------------------------
// `target` is a 10-digit Indian mobile number; Fonnte adds the 91 prefix.
export async function sendWhatsApp(target: string, message: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const form = new FormData();
    form.append('target', target);
    form.append('message', message);
    form.append('countryCode', '91');
    const res = await fetch('https://api.fonnte.com/send', {
      method: 'POST', headers: { Authorization: Deno.env.get('FONNTE_TOKEN') ?? '' }, body: form,
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok && body.status !== false) return { ok: true };
    return { ok: false, error: String(body.reason ?? `HTTP ${res.status}`) };
  } catch (e) {
    return { ok: false, error: String((e as Error).message) };
  }
}

// ---- Telegram --------------------------------------------------------------
export const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export async function sendTelegram(html: string): Promise<void> {
  try {
    await fetch(`https://api.telegram.org/bot${Deno.env.get('TELEGRAM_BOT_TOKEN')}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: Deno.env.get('TELEGRAM_ADMIN_CHAT_ID'), text: html, parse_mode: 'HTML' }),
    });
  } catch (e) { console.error('telegram failed', e); }
}

// Sends a customer WhatsApp message at most once per order+event, and logs it.
// A failure here never fails the calling request.
export async function notifyCustomer(orderId: string, userId: string, mobile: string | null, event: string, text: string) {
  try {
    const { error } = await admin.from('notification_log')
      .insert({ order_id: orderId, user_id: userId, channel: 'WHATSAPP', event, status: 'PENDING' });
    if (error) return;                    // unique violation = already sent
    if (!mobile) {
      await admin.from('notification_log').update({ status: 'FAILED', error: 'no mobile' })
        .eq('order_id', orderId).eq('event', event).eq('channel', 'WHATSAPP');
      return;
    }
    const r = await sendWhatsApp(mobile, text);
    await admin.from('notification_log').update({ status: r.ok ? 'SENT' : 'FAILED', error: r.error ?? null })
      .eq('order_id', orderId).eq('event', event).eq('channel', 'WHATSAPP');
    if (!r.ok) await sendTelegram(`⚠️ WhatsApp failed (${esc(event)}): ${esc(r.error)}`);
  } catch (e) { console.error('notify failed', e); }
}

export async function audit(adminId: string, action: string, table: string, recordId: string | null, newValue: unknown) {
  await admin.from('audit_logs').insert({ admin_id: adminId, action, table_name: table, record_id: recordId, new_value: newValue });
}
