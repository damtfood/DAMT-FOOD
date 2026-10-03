import { admin, audit, authUser, esc, handle, HttpError, hmac, notifyCustomer, randomCode, sendTelegram } from '../_shared/util.ts';

const NEXT: Record<string, string[]> = {
  PENDING: ['CONFIRMED', 'CANCELLED'],
  CONFIRMED: ['PREPARING', 'CANCELLED'],
  PREPARING: ['PACKED', 'CANCELLED'],
  PACKED: ['ASSIGNED', 'CANCELLED'],
  ASSIGNED: ['ASSIGNED', 'OUT_FOR_DELIVERY', 'CANCELLED'],   // ASSIGNED->ASSIGNED = reassign
};
// DELIVERED is only reachable through verify-delivery-otp.

const MESSAGES: Record<string, (n: number) => string> = {
  CONFIRMED: (n) => `Your DAMT Food order #${n} is confirmed.`,
  PREPARING: (n) => `Your order #${n} is being prepared.`,
  PACKED: (n) => `Your order #${n} is packed and waiting for a delivery partner.`,
  ASSIGNED: (n) => `A delivery partner has been assigned to your order #${n}.`,
  CANCELLED: (n) => `Your order #${n} was cancelled. Contact us if you have questions.`,
};

Deno.serve(handle(async (req) => {
  const u = await authUser(req, { roles: ['admin', 'delivery_partner'] });
  const b = await req.json().catch(() => ({}));
  const status = String(b.status ?? '');

  const { data: o } = await admin.from('orders')
    .select('id, order_number, customer_id, delivery_partner_id, order_status')
    .eq('id', b.order_id).maybeSingle();
  if (!o) throw new HttpError(404, 'Order not found');
  if (!(NEXT[o.order_status] ?? []).includes(status)) throw new HttpError(409, `Cannot move from ${o.order_status} to ${status}`);

  if (u.role === 'delivery_partner') {
    if (!(status === 'OUT_FOR_DELIVERY' && o.delivery_partner_id === u.id)) throw new HttpError(403, 'Not allowed');
  }

  const patch: Record<string, unknown> = { order_status: status, updated_at: new Date().toISOString() };
  if (status === 'ASSIGNED') {
    const { data: partner } = await admin.from('profiles').select('id, role, is_active').eq('id', b.partner_id).maybeSingle();
    if (!partner || partner.role !== 'delivery_partner' || !partner.is_active) throw new HttpError(400, 'Choose an active delivery partner');
    patch.delivery_partner_id = partner.id;
  }
  if (status === 'CANCELLED') {
    const reason = String(b.reason ?? '').trim();
    if (reason.length < 3) throw new HttpError(400, 'Enter a cancellation reason');
    patch.cancel_reason = reason.slice(0, 300);
  }

  // Compare-and-set so two simultaneous clicks cannot both apply.
  const { data: changed } = await admin.from('orders').update(patch)
    .eq('id', o.id).eq('order_status', o.order_status).select('id');
  if (!changed?.length) throw new HttpError(409, 'The order changed. Refresh and try again.');

  await admin.from('order_status_history').insert({ order_id: o.id, status, changed_by: u.id, notes: patch.cancel_reason ?? null });
  if (status === 'CANCELLED') await admin.rpc('restock_order', { p_order: o.id });
  if (u.role === 'admin') await audit(u.id, `ORDER_${status}`, 'orders', o.id, patch);

  const { data: cust } = await admin.from('profiles').select('mobile_number').eq('id', o.customer_id).single();
  if (status === 'OUT_FOR_DELIVERY') {
    const code = randomCode(6);
    await admin.from('delivery_otps').upsert({
      order_id: o.id, otp_hash: await hmac(`delivery:${o.id}:${code}`),
      expires_at: new Date(Date.now() + 12 * 3600_000).toISOString(), attempts: 0,
    });
    await notifyCustomer(o.id, o.customer_id, cust?.mobile_number ?? null, 'OUT_FOR_DELIVERY',
      `Your order #${o.order_number} is out for delivery. Delivery code: ${code}. Share it with the delivery partner only when you receive your order.`);
  } else if (MESSAGES[status]) {
    await notifyCustomer(o.id, o.customer_id, cust?.mobile_number ?? null, status, MESSAGES[status](o.order_number));
  }
  await sendTelegram(`📦 Order #${o.order_number} → <b>${esc(status)}</b>`);
  return { success: true, status };
}));
