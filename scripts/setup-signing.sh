#!/bin/zsh
# このMacの中だけで使う、固定の署名用証明書を作る（最初に1回だけ実行する）。
#
# 証明書なしでビルドすると、ビルドし直すたびに macOS が別のアプリと見なし、
# キーチェーンの確認やマイクの許可を毎回求められる。固定の証明書で署名すると、それが止まる。
# 実行中に Mac のパスワードを求める確認が出る。
set -euo pipefail

NAME="MeetNote Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "署名用証明書「$NAME」はすでにあります。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS 標準の openssl を使う（Homebrew 版が作る p12 は security コマンドで読めないことがある）。
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout pass:meetnote-local

security import "$WORK/id.p12" -k "$KEYCHAIN" -P meetnote-local -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "署名用証明書「$NAME」を作りました。次回の ./scripts/build.sh から使われます。"
echo "初回のビルドで「codesign がキーを使おうとしています」と出たら「常に許可」を押してください。"
