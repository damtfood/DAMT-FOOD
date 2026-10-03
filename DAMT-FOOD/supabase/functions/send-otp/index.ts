import { admin, authUser, handle, HttpError, hmac, randomCode, sendWhatsApp } from '../_shared/util.ts';

Deno.serve(handle(async (req) => {
  const u = await authUser(req, { roles: ['customer'] });
  const body = await req.json().catch(() => ({}));
  const mobile = String(body.mobile ?? '').replace(/\D/g, '').replace(/^91(?=\d{10}$)/, '');
  if (!/^[6-9]\d{9}$/.test(mobile)) throw new HttpError(400, 'Enter a valid 10-digit mobile number');

  const { data: taken } = await admin.from('profiles').select('id').eq('mobile_number', mobile).neq('id', u.id).maybeSingle();
  if (taken) throw new HttpError(409, 'This mobile number is already registered');

  const code = randomCode(6);
  const hash = await hmac(`${u.id}:${mobile}:${code}`);
  // Atomic: only succeeds if the last OTP was sent more than 60 seconds ago.
  const { data: issued, error } = await admin.rpc('issue_otp', { p_user: u.id, p_mobile: mobile, p_hash: hash });
  if (error) throw error;
  if (!issued) throw new HttpError(429, 'Please wait 60 seconds before requesting another code');

  const r = await sendWhatsApp(mobile, `Your DAMT Food verification code is ${code}. It is valid for 5 minutes. Do not share it with anyone.`);
  if (!r.ok) throw new HttpError(502, 'Could not send the WhatsApp message. Try again in a minute.');
  return { success: true };
}));
