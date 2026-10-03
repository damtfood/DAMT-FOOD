# DAMT Food

Three Android apps (Customer, Admin, Delivery Partner) for Murugan Trader, sharing one Supabase backend.

| Part | Folder | Hosted on |
|---|---|---|
| Landing page + `/api/health` | `public/`, `api/` | Vercel (https://damtfood.vercel.app) |
| Database, RLS, Edge Functions | `supabase/` | Supabase |
| Customer / Admin / Delivery apps | `apps/*` | APK (Flutter) |

## 1. Upload to GitHub
Upload everything in this folder to `damtfood/DAMT-FOOD` (private). Secrets are never committed (`.gitignore` covers `.env`, keystores, `key.properties`).
Vercel redeploys automatically when the repo changes.

## 2. Supabase (once)
1. SQL Editor -> paste `supabase/schema.sql` -> Run (fresh project only).
2. Create the first admin: Authentication -> Users -> Add user, email `admin@staff.damtfood.app` + a strong password (tick "Auto confirm"). Then in SQL Editor:
   ```sql
   update profiles set role='admin', is_verified=true, full_name='Admin'
   where email='admin@staff.damtfood.app';
   ```
   The admin signs in to the Admin app with username `admin`.
3. Set your shop location (used for delivery distance):
   ```sql
   update store_settings set value='<lat>' where key='store_lat';
   update store_settings set value='<lng>' where key='store_lng';
   ```
4. Edge Function secrets (never commit these):
   ```
   supabase secrets set OTP_PEPPER=<long random string> FONNTE_TOKEN=... TELEGRAM_BOT_TOKEN=... TELEGRAM_ADMIN_CHAT_ID=... GOOGLE_MAPS_API_KEY=...
   ```
5. Deploy the functions (needs the Supabase CLI):
   ```
   supabase login
   supabase link --project-ref empdwsjxyikkgmkeldka
   supabase functions deploy --project-ref empdwsjxyikkgmkeldka --no-verify-jwt
   ```
   Functions: `send-otp`, `verify-otp`, `create-order`, `update-order-status` (also used for assigning a delivery partner), `verify-delivery-otp`, `admin-create-user`.
6. Delivery partners: create them with the `admin-create-user` function (admin only; body: `username`, `password`, `full_name`, `mobile`). No public signup.

## 3. Build the APKs (Flutter installed, Windows PowerShell)
```
.\scripts\setup_app.ps1 customer
cd out\customer
flutter build apk --release
```
Output: `out\customer\build\app\outputs\flutter-apk\app-release.apk`. Repeat for `admin` and `delivery`.
(macOS/Linux: `./scripts/setup_app.sh customer`.)

Package names: `com.murugantrader.damtfood.customer`, `.admin`, `.delivery`.

## 4. Google sign-in (Customer app only)
- Android OAuth client in Google Cloud: package `com.murugantrader.damtfood.customer` + SHA-1 of the signing key.
  Debug key: `keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android`
- Add the Android client ID after the Web client ID in Supabase → Auth → Providers → Google → Client IDs (comma-separated).
- Release builds here use the debug key by default, so the debug SHA-1 works. For Play Store, create a real keystore and register its SHA-1 too.

## Included vs. still to build
Included: hardened schema + RLS, Google login, WhatsApp OTP (hashed, 60s cooldown, 5 attempts, 5 min expiry), server-side order creation (COD only), admin order flow with history and cancel reason, audit log, WhatsApp + Telegram alerts, delivery partner assignment, delivery OTP verification (backend), delivery partner assigned-order list.

Still to build (next): cart/checkout screens, UPI payment webhook (only COD is enabled until a gateway with signed webhooks is chosen), delivery OTP / mark-delivered screens in the Delivery app, delivery proof upload, refunds, reports, product management screens.

## Security notes
- The apps contain only the Supabase URL, the publishable key and the Google Web client ID (all public).
- Never put the Supabase secret key, Fonnte token, Telegram token or Google client secret in the apps or in GitHub.
