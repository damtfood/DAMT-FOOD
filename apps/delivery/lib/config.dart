// Only PUBLIC values belong here. Never put the Supabase secret key,
// Fonnte token, Telegram token or Google client secret in the app.
class AppConfig {
  static const supabaseUrl = 'https://empdwsjxyikkgmkeldka.supabase.co';
  static const supabasePublishableKey = 'sb_publishable_GqRIP8W1OmCEebX653LlHg_JLQt52-2';
  static const googleWebClientId =
      '258926525351-taspshe05dcb234jppkr8gnp1v49rjjg.apps.googleusercontent.com';
  // Admin / Delivery usernames are mapped to this email domain in Supabase Auth.
  static const staffEmailDomain = 'staff.damtfood.app';
}
