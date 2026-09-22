#!/bin/zsh
# VoIP push certificate for Twilio.
#   ./voip-cert.sh csr            → certs/voip.csr to upload at developer.apple.com
#                                   (Certificates → + → VoIP Services Certificate → com.techadnank9.assistant)
#   ./voip-cert.sh import X.cer   → certs/voip.pem, ready for `npm run setup`
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs

case "${1:-}" in
  csr)
    [[ -f certs/voip.key ]] || openssl genrsa -out certs/voip.key 2048
    openssl req -new -key certs/voip.key -out certs/voip.csr -subj "/CN=Assistant VoIP/emailAddress=dev@example.com"
    echo "Upload certs/voip.csr to Apple, download the .cer, then: ./voip-cert.sh import ~/Downloads/voip_services.cer"
    ;;
  import)
    openssl x509 -inform der -in "$2" -out certs/voip.pem
    openssl x509 -in certs/voip.pem -noout -subject
    echo "Saved certs/voip.pem. Now run: npm run setup"
    ;;
  *)
    echo "usage: $0 csr | import <file.cer>"; exit 1 ;;
esac
