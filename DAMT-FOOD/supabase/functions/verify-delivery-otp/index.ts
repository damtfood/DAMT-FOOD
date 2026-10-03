import { admin, authUser, esc, handle, HttpError, hmac, notifyCustomer, safeEqual, sendTelegram } from '../_shared/util.ts';

Deno.serve(handle(async (req) => {
  const u = await authUser(req, { roles: ['delivery_partner'] });
  const b = await req.json().catch(() => ({}));
  const otp = String(b.otp ?? '');
  if (!/^\d{6}$/.test(otp)) throw new HttpError(400, 'Enter the 6-digit code');

  const { data: o } = await admin.from('orders')
    .select('id, order_number, customer_id, payment_method, payment_status, final_amount')
    .eq('id', b.order_id).eq('delivery_partner_id', u.id).eq('order_status', 'OUT_FOR_DELIVERY').maybeSingle();
  if (!o) throw new HttpError(404, 'Order not found');

  const { data, error } = await admin.rpc('delivery_otp_attempt', { p_order: o.id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new HttpError(400, 'Code expired or too many attempts. Ask the admin for help.');
  if (!safeEqual(await hmac(`delivery:${o.id}:${otp}`), row.o_hash)) throw new HttpError(400, 'Incorrect code');

  const proof = b.proof_path ? String(b.proof_path) : null;
  if (proof && !proof.startsWith(`${u.id}/`)) throw new HttpError(400, 'Invalid proof file');

  const patch: Record<string, unknown> = { order_status: 'DELIVERED', updated_at: new Date().toISOString() };
  const isCod = o.payment_method === 'COD';
  if (isCod) patch.payment_status = 'SUCCESS';
  const { data: changed } = await admin.from('orders').update(patch)
    .eq('id', o.id).eq('order_status', 'OUT_FOR_DELIVERY').select('id');
  if (!changed?.length) throw new HttpError(409, 'Order already updated');

  await admin.from('order_status_history').insert({ order_id: o.id, status: 'DELIVERED', changed_by: u.id, notes: 'Delivery OTP verified' });
  await admin.from('delivery_otps').delete().eq('order_id', o.id);
  if (proof) await admin.from('delivery_proofs').insert({ order_id: o.id, partner_id: u.id, storage_path: proof });
  if (isCod) {
    await admin.from('cod_collections').upsert({ order_id: o.id, partner_id: u.id, amount: o.final_amount });
    await admin.from('payments').insert({ order_id: o.id, method: 'COD', amount: o.final_amount, status: 'SUCCESS' });
  }

  const { data: cust } = await admin.from('profiles').select('mobile_number').eq('id', o.customer_id).single();
  await notifyCustomer(o.id, o.customer_id, cust?.mobile_number ?? null, 'DELIVERED',
    `Your DAMT Food order #${o.order_number} has been delivered. Thank you!`);
  await sendTelegram(`✅ Order #${o.order_number} delivered${isCod ? ` • COD ₹${o.final_amount} collected by ${esc(u.full_name)}` : ''}`);
  return { success: true };
}));
