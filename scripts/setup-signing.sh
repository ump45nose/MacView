#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "用法：scripts/setup-signing.sh" >&2
  exit 2
fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
identity="MacView Local Development"
if ! keychain=$(/usr/bin/security login-keychain 2>/dev/null); then
  echo "无法定位登录钥匙串，请先解锁后重试。" >&2
  exit 1
fi
keychain=$(printf '%s' "$keychain" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')
if /usr/bin/security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo "$identity 已存在，继续复用，不生成替代证书。"
  exit 0
else
  status=$?
  if [ "$status" -ne 44 ]; then
    echo "无法检查登录钥匙串，请先解锁后重试。" >&2
    exit 1
  fi
fi

echo "首次创建签名身份；此步骤可能弹出钥匙串授权，请在场确认。随后打包复用同一证书。"
umask 077
mkdir -p "$root/build"
scratch=$(mktemp -d "$root/build/signing.XXXXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
cat > "$scratch/certificate.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = signing
[dn]
CN = $identity
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
/usr/bin/openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 -nodes \
  -keyout "$scratch/private.key" -out "$scratch/certificate.pem" -config "$scratch/certificate.cnf" >/dev/null 2>&1
# 与 Lasso 一样使用 PEM sequence，避免空口令 PKCS#12 兼容问题。私钥只在 0700 暂存目录中存在。
cat "$scratch/certificate.pem" "$scratch/private.key" > "$scratch/identity.pem"
/usr/bin/security import "$scratch/identity.pem" -k "$keychain" -f pemseq -t agg -x -T /usr/bin/codesign
echo "$identity 已导入登录钥匙串，私钥不可导出，仅授权 codesign 使用。"
