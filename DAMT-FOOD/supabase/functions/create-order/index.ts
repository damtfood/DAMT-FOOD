import { admin, authUser, esc, handle, HttpError, notifyCustomer, sendTelegram } from '../_shared/util.ts';

function haversineKm(aLat: number, aLng: number, bLat: number, bLng: number) {
  const r = (d: number) => (d * Math.PI) / 180;
  const h = Math.sin(r(bLat - aLat) / 2) ** 2 + Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(r(bLng - aLng) / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

// Road distance from Google when GOOGLE_MAPS_API_KEY is set; otherwise an
// estimate (straight line x 1.3). Always computed on the server.
async function distanceKm(sLat: number, sLng: number, dLat: number, dLng: number): Promise<number> {
  const key = Deno.env.get('GOOGLE_MAPS_API_KEY');
  if (key) {
    try {
      const url = `https://maps.googleapis.com/maps/api/distancematrix/json?origins=${sLat},${sLng}&destinations=${dLat},${dLng}&key=${key}`;
      const data = await (await fetch(url)).json();
      const el = data?.rows?.[0]?.elements?.[0];
      if (data.status === 'OK' && el?.status === 'OK') return el.distance.value / 1000;
    } catch (_) { /* fall through to estimate */ }
  }
  return haversineKm(sLat, sLng, dLat, dLng) * 1.3;
}

Deno.serve(handle(async (req) => {
  const u = await authUser(req, { roles: ['customer'], requireVerified: true });
  const b = await req.json().catch(() => ({}));

  const idem = String(b.idempotency_key ?? '');
  if (idem.length < 8 || idem.length > 64) throw new HttpError(400, 'Invalid request');
  if (b.payment_method !== 'COD') throw new HttpError(400, 'Only Cash on Delivery is available right now');
  if (!Array.isArray(b.items) || b.items.length === 0 || b.items.length > 40) throw new HttpError(400, 'Your cart is empty');
  const items = b.items.map((i: Record<string, unknown>) => ({
    variant_id: String(i.variant_id), qty: Math.floor(Number(i.qty)), note: i.note ? String(i.note).slice(0, 300) : null,
  }));

  const { data: addr } = await admin.from('addresses').select('latitude, longitude').eq('id', b.address_id).eq('user_id', u.id).maybeSingle();
  if (!addr) throw new HttpError(400, 'Choose a delivery address');

  const { data: st } = await admin.from('store_settings').select('key, value');
  const s = Object.fromEntries((st ?? []).map((r) => [r.key, Number(r.value)]));
  if (!s.store_lat || !s.store_lng) throw new HttpError(503, 'The store is not ready to take orders yet');

  const km = Math.round((await distanceKm(s.store_lat, s.store_lng, addr.latitude, addr.longitude)) * 100) / 100;
  if (km > (s.max_delivery_km || 12)) throw new HttpError(400, `Sorry, we deliver only within ${s.max_delivery_km || 12} km`);

  const { data: slab } = await admin.from('delivery_pricing').select('fee')
    .lte('min_km', km).gte('max_km', km).order('min_km').limit(1).maybeSingle();
  if (!slab) throw new HttpError(400, 'Delivery is not available for this address');

  let orderId: string | null = null;
  const { data, error } = await admin.rpc('place_order', {
    p_customer: u.id, p_address: b.address_id, p_method: 'COD', p_items: items,
    p_fee: slab.fee, p_distance: km, p_coupon: b.coupon_code ? String(b.coupon_code).slice(0, 30) : null, p_idem: idem,
  });
  if (error) {
    if (error.code !== '23505') throw error;           // duplicate tap racing: reuse the first order
    const { data: ex } = await admin.from('orders').select('id').eq('customer_id', u.id).eq('idempotency_key', idem).single();
    orderId = ex?.id ?? null;
  } else orderId = data as string;
  if (!orderId) throw new HttpError(500, 'Could not place the order');

  const { data: o } = await admin.from('orders').select('order_number, final_amount').eq('id', orderId).single();
  await notifyCustomer(orderId, u.id, u.mobile_number, 'ORDER_PLACED',
    `Thank you for your order #${o!.order_number} with DAMT Food. Total ₹${o!.final_amount} (Cash on Delivery). We will confirm it shortly.`);
  await sendTelegram(`🛒 <b>New order #${o!.order_number}</b>\n${esc(u.full_name)} • ₹${o!.final_amount} • COD • ${km} km`);
  return { order_id: orderId, order_number: o!.order_number, final_amount: o!.final_amount };
}));
