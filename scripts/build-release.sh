#!/usr/bin/env bash
# Gera o app de produção (AAB para a Play Store e APK para instalar direto).
#
#   API_URL=https://api.seudominio.com.br [OSRM_URL=https://rotas.seudominio.com.br] scripts/build-release.sh
#
# Precisa de android/key.properties com a chave de upload (ver README, "Build de produção").
set -euo pipefail
cd "$(dirname "$0")/.."

: "${API_URL:?Defina API_URL (endereço HTTPS da API).}"
case "$API_URL" in
  https://*) ;;
  *) echo "API_URL precisa ser HTTPS (a build de release recusa HTTP)." >&2; exit 1 ;;
esac
if [[ ! -f android/key.properties ]]; then
  echo "Falta android/key.properties com a chave de upload. Veja o README." >&2
  exit 1
fi

defines=(--dart-define=API_URL="$API_URL")
if [[ -n "${OSRM_URL:-}" ]]; then
  defines+=(--dart-define=OSRM_URL="$OSRM_URL")
else
  echo "Aviso: sem OSRM_URL, as distâncias ficam em linha reta (sem rota por rua)." >&2
fi

flutter pub get
flutter analyze
flutter test
flutter build appbundle --release "${defines[@]}"
flutter build apk --release "${defines[@]}"
echo
echo "Prontos:"
echo "  build/app/outputs/bundle/release/app-release.aab  (Play Store)"
echo "  build/app/outputs/flutter-apk/app-release.apk     (instalação direta)"
