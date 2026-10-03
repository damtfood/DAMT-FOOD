import { admin, audit, authUser, handle, HttpError } from '../_shared/util.ts';

// Creates a Delivery Partner login (username + password). No public signup exists.
Deno.serve(handle(async (req) => {
  const a = await authUser(req, { roles: ['admin'] });
  const b = await req.json().catch(() => ({}));
  const username = String(b.username ?? '').trim().toLowerCase();
  const password = String(b.password ?? '');
  const fullName = String(b.full_name ?? '').trim().slice(0, 80);
  const mobile = String(b.mobile ?? '').replace(/\D/g, '').slice(-10);

  if (!/^[a-z0-9._]{4,24}$/.test(username)) throw new HttpError(400, 'Username: 4-24 letters, numbers, dot or underscore');
  if (password.length < 10 || !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/\d/.test(password))
    throw new HttpError(400, 'Password needs 10+ characters with upper case, lower case and a number');
  if (fullName.length < 2) throw new HttpError(400, 'Enter the partner name');
  if (mobile && !/^[6-9]\d{9}$/.test(mobile)) throw new HttpError(400, 'Enter a valid 10-digit mobile number');

  const { data, error } = await admin.auth.admin.createUser({
    email: `${username}@staff.damtfood.app`, password, email_confirm: true, user_metadata: { full_name: fullName },
  });
  if (error || !data.user) throw new HttpError(400, 'Could not create the account. The username may already exist.');

  const { error: e2 } = await admin.from('profiles').update({
    role: 'delivery_partner', username, full_name: fullName, mobile_number: mobile || null,
    is_verified: true, created_by_admin_id: a.id,
  }).eq('id', data.user.id);
  if (e2) {
    await admin.auth.admin.deleteUser(data.user.id);
    throw new HttpError(400, 'Could not save the profile. The mobile number may already be in use.');
  }
  await audit(a.id, 'DELIVERY_PARTNER_CREATED', 'profiles', data.user.id, { username });
  return { success: true, id: data.user.id };
}));
