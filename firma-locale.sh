#!/bin/bash
# Crea (una volta sola) un certificato locale per firmare Jarvis in modo stabile.
# Perche': con la firma "ad-hoc" ogni ricompilazione cambia l'impronta del binario,
# e il Mac considera Jarvis un'app nuova -> perde il permesso di Registrazione schermo
# e Microfono e te li chiede di continuo.
#
# Nessuna password admin: finisce nel tuo portachiavi di login.
set -euo pipefail
NOME="Jarvis Locale"
CERT="/tmp/jarvis-cert.pem"
CHIAVE="/tmp/jarvis-key.pem"
P12="/tmp/jarvis-cert.p12"
PASS="jarvis-firma-locale"

if security find-certificate -c "$NOME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Il certificato $NOME esiste gia': niente da fare."
  exit 0
fi

echo "[1/4] genero chiave e certificato (valido 10 anni)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CHIAVE" -out "$CERT" -days 3650 \
  -subj "/CN=$NOME" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

echo "[2/4] lo metto nel portachiavi di login..."
openssl pkcs12 -export -inkey "$CHIAVE" -in "$CERT" -out "$P12" -passout "pass:$PASS" 2>/dev/null
security import "$P12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "[3/4] mi fido per la firma di codice..."
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$CERT" >/dev/null 2>&1 || \
  security add-trusted-cert -p codeSign -r trustRoot -k ~/Library/Keychains/login.keychain-db "$CERT"

echo "[4/4] cancello le copie temporanee della chiave privata..."
rm -f "$CHIAVE" "$P12"

echo
echo "Fatto. D'ora in poi Jarvis verra' firmato con: $NOME"
echo "Verifica:  security find-identity -v -p codesigning | grep Jarvis"
