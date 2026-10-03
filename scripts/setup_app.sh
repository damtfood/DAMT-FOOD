#!/usr/bin/env bash
# Usage (from repo root):  ./scripts/setup_app.sh customer
set -e
APP="$1"
case "$APP" in customer) LABEL="DAMT Food";; admin) LABEL="DAMT Food Admin";; delivery) LABEL="DAMT Food Delivery";; *) echo "usage: $0 customer|admin|delivery"; exit 1;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$APP"
flutter create --org com.murugantrader.damtfood --project-name "$APP" --platforms android "$OUT"
cp -r "$ROOT/apps/$APP/lib" "$ROOT/apps/$APP/assets" "$OUT/"
cp "$ROOT/apps/$APP/pubspec.yaml" "$OUT/pubspec.yaml"
M="$OUT/android/app/src/main/AndroidManifest.xml"
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
sed -i "s#android:label=\"[^\"]*\"#android:label=\"$LABEL\"#" "$M"
cd "$OUT" && flutter pub get && dart run flutter_launcher_icons
echo "Done. Next: cd out/$APP && flutter build apk --release"
