import { admin, authUser, handle, HttpError, hmac, safeEqual } from '../_shared/util.ts';

Deno.serve(handle(async (req) => {
  const u = await authUser(req, { roles: ['customer'] });
  const body = await req.json().catch(() => ({}));
  const otp = String(body.otp ?? '');
  if (!/^\d{6}$/.test(otp)) throw new HttpError(400, 'Enter the 6-digit code');

  // Counts the attempt atomically; returns nothing if expired or 5 attempts used.
  const { data, error } = await admin.rpc('otp_attempt', { p_user: u.id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new HttpError(400, 'Code expired or too many attempts. Request a new code.');

  const candidate = await hmac(`${u.id}:${row.o_mobile}:${otp}`);
  if (!safeEqual(candidate, row.o_hash)) throw new HttpError(400, 'Incorrect code');

  const { error: e2 } = await admin.from('profiles').update({ mobile_number: row.o_mobile, is_verified: true }).eq('id', u.id);
  if (e2) {
    if (e2.code === '23505') throw new HttpError(409, 'This mobile number is already registered');
    throw e2;
  }
  await admin.from('otp_requests').delete().eq('user_id', u.id);   // one-time use
  return { success: true };
}));
