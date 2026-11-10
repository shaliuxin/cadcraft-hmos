#!/usr/bin/env bash
# 为 cadcraft-hmos 生成一份【本地】调试签名（OpenHarmony 本地 CA 链），
# 绑独立 bundle 名 io.github.shaliuxin.cadcraft.hmos，不与用户 photocraft 的
# AGC profile 冲突。产出 signing/ 下的 .cer/.p12/.p7b，供 build-profile.json5 引用。
#
# 注意：这是本地自签 CA 链。HarmonyOS 7.0 真机可能拒绝纯本地签名；若安装被拒，
# 请在 DevEco 里把 bundle 名改为本名、用"自动签名"让 AGC 签发正式调试 profile。
set -euo pipefail

DEVECO="${DEVECO_HOME:-/c/Program Files/Huawei/DevEco Studio}"
JAVA="$DEVECO/jbr/bin/java.exe"
SIGTOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/signing"
BUNDLE="${CADCRAFT_BUNDLE:-io.github.shaliuxin.cadcraft.hmos}"
KEYALIAS="cadcraft-debug"
# 固定口令（仅本地调试用，别用于发布）
KEYPW="sc_dbg_key_20261104_a1b2c3d4e5f6g7h8i9j0k"
STOREPW="sc_dbg_store_20261104_0f1e2d3c4b5a6g7h8i9j0"
# 设备 UDID（取自已有 profile，HPR-W72 在其中）
UID1="B700BA9C45AEFBE60C1C5510B72D7A9A7FAC84F23EE05BB6BC243339DB9A2AA4"
UID2="90243F3456A3C80C9F2F4467B931FDFE1005A461328D7CF934FA8F49F9A5877F"

mkdir -p "$OUT"
cd "$OUT"
echo "bundle=$BUNDLE out=$OUT"
run() { echo "+ $JAVA -jar $SIGTOOL $*"; "$JAVA" -jar "$SIGTOOL" "$@" 2>&1 | grep -iE "success|error|exception" | tail -2 || true; }

# 1) 根 CA 密钥对
rm -f root.jks root-ca.cer app-sub.jks app-sub-ca.cer app.p12 app-cert.cer profile.jks profile-ca.cer profile-cert.cer app-profile.json cadcraft-debug.p7b
run generate-keypair -keyAlias oh-root-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile root.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"

# 2) 自签根证书
run generate-ca -keyAlias oh-root-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -subject "C=CN,O=cadcraft,OU=dev,CN=CADCraft Root CA" \
  -keystoreFile root.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile root-ca.cer

# 3) 应用签名子 CA 密钥对（由根 CA 签发）
run generate-keypair -keyAlias oh-app-sub-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile app-sub.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"
run generate-ca -keyAlias oh-app-sub-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -issuer "C=CN,O=cadcraft,OU=dev,CN=CADCraft Root CA" \
  -issuerKeyAlias oh-root-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile root.jks \
  -subject "C=CN,O=cadcraft,OU=dev,CN=CADCraft App Signing CA" \
  -keystoreFile app-sub.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile app-sub-ca.cer

# 4) 应用密钥对（p12，供 hvigor storeFile）
run generate-keypair -keyAlias "$KEYALIAS" -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile app.p12 -keystorePwd "$STOREPW" -keyPwd "$KEYPW"

# 5) 应用签名证书（由应用子 CA 签发，含 root+sub 双链）
run generate-app-cert -keyAlias "$KEYALIAS" -keyPwd "$KEYPW" \
  -issuer "C=CN,O=cadcraft,OU=dev,CN=CADCraft App Signing CA" \
  -issuerKeyAlias oh-app-sub-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile app-sub.jks \
  -subject "C=CN,O=cadcraft,OU=dev,CN=cadcraft-hmos" \
  -validity 3650 -signAlg SHA256withECDSA \
  -keystoreFile app.p12 -keystorePwd "$STOREPW" \
  -outForm certChain -rootCaCertFile root-ca.cer -subCaCertFile app-sub-ca.cer \
  -outFile app-cert.cer

# 6) profile 签名子 CA 密钥对
run generate-keypair -keyAlias oh-profile-ca -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile profile.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW"

# 7) profile 签名 CA 证书（由根 CA 签发）
run generate-ca -keyAlias oh-profile-ca -keyAlg ECC -keySize NIST-P-256 -signAlg SHA256withECDSA \
  -issuer "C=CN,O=cadcraft,OU=dev,CN=CADCraft Root CA" \
  -issuerKeyAlias oh-root-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile root.jks \
  -subject "C=CN,O=cadcraft,OU=dev,CN=CADCraft Profile CA" \
  -keystoreFile profile.jks -keystorePwd "$STOREPW" -keyPwd "$KEYPW" \
  -outFile profile-ca.cer

# 7) provision profile 证书（由 profile CA 签发，含双 CA 链）
run generate-profile-cert -keyAlias oh-profile-ca -keyPwd "$KEYPW" \
  -issuer "C=CN,O=cadcraft,OU=dev,CN=CADCraft Profile CA" \
  -issuerKeyAlias oh-profile-ca -issuerKeyPwd "$KEYPW" -issuerKeystorePwd "$STOREPW" -issuerKeystoreFile profile.jks \
  -subject "C=CN,O=cadcraft,OU=dev,CN=CADCraft Provision Profile Debug" \
  -validity 3650 -signAlg SHA256withECDSA \
  -rootCaCertFile root-ca.cer -subCaCertFile profile-ca.cer \
  -outForm certChain -keystoreFile profile.jks -keystorePwd "$STOREPW" -outFile profile-cert.cer

# 8) 生成 profile json（含 bundle 名 + 设备 UDID）
NB=$(date -u +%s); NA=$((NB + 3*365*24*3600))
# sign-app 要求 profile 的 development-certificate 是【单张 leaf】证书的 base64，且必须是
# 【DER 编码】+【URL-safe base64】(+/ 换成 -_、去 padding)。踩坑结论：
#   - 放整条链（app-cert.cer 含 leaf+子CA+根 三张）→ "Decode Base64 certificate failed"
#   - 用 PEM 文本的 base64（或标准 base64，含 + /）→ sign-app 报 "Illegal base64 character 2b"
#   - 正确做法：openssl 取第一张 leaf → DER → URL-safe base64。sign-app 时 -appCertFile 仍用整条链。
awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' app-cert.cer > app-leaf.pem
openssl x509 -in app-leaf.pem -outform DER -out app-leaf.der
APP_B64=$(python -c "import base64;print(base64.urlsafe_b64encode(open('app-leaf.der','rb').read()).decode())")
cat > app-profile.json <<EOF
{
  "version-name": "2.0.0",
  "version-code": 1900,
  "uuid": "6c1a0e2b-4f3d-4b7a-9c2e-cadcraft01",
  "validity": { "not-before": $NB, "not-after": $NA },
  "type": "debug",
  "bundle-info": {
    "developer-id": "55530755",
    "development-certificate": "$APP_B64",
    "bundle-name": "$BUNDLE",
    "apl": "normal",
    "app-feature": "hos_normal_app",
    "app-identifier": "6917620714977119980"
  },
  "baseapp-info": {},
  "permissions": {},
  "debug-info": { "device-ids": ["$UID1", "$UID2"], "device-id-type": "udid" },
  "acls": { "allowed-acls": [] },
  "app-privilege-capabilities": [],
  "issuer": "pki_internal"
}
EOF

# 9) 签 profile -> p7b
run sign-profile -mode localSign -keyAlias oh-profile-ca -keyPwd "$KEYPW" \
  -profileCertFile profile-cert.cer -inFile app-profile.json \
  -signAlg SHA256withECDSA -keystoreFile profile.jks -keystorePwd "$STOREPW" \
  -outFile cadcraft-debug.p7b

echo "=== 产物 ==="
ls -la "$OUT"/*.cer "$OUT"/*.p12 "$OUT"/*.p7b 2>&1 | tr -d '\r'
echo "=== 校验 p7b ==="
"$JAVA" -jar "$SIGTOOL" verify-profile -inFile "$OUT/cadcraft-debug.p7b" 2>&1 | grep -iE "verifiedPassed|message|bundle-name" | head
