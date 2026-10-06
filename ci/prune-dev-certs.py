#!/usr/bin/env python3
"""清理 CI 自己造出来的旧开发证书。

## 为什么需要这一步

GitHub runner **每次都是全新的机器，keychain 里没有任何私钥**。云端签名
（`-allowProvisioningUpdates`）拿不到能复用的私钥，就只能在 Apple 那边
**新造一对密钥 + 一张证书**。于是：

    **每发布一次，就烧掉一个证书额度。**

攒到上限就再也签不了名。实测踩到：v2.1 的 Archive 步骤直接失败 ——

    error: Choose a certificate to revoke. Your account has reached the
           maximum number of certificates. To create a new one, you must
           choose a certificate to revoke.
    error: No profiles for 'com.smile.intoxication.applewatchhealth' were found

当时账号上积了 **12 张**开发证书，全部叫 "Created via API"（8 张来自第一天，
4 张来自当天）—— 一张都没复用。

## 为什么吊销是安全的

- 这些证书的**私钥早随 runner 销毁了**，一张都复用不了（留着毫无价值）；
- **已经上传到 App Store Connect 的构建不受证书吊销影响** —— 包早就交付了。

## 边界（刻意收得很紧）

只动**同时满足**三个条件的证书，其它一律不碰：

1. `certificateType == DEVELOPMENT`
2. `displayName == "Created via API"`（CI 造的东西就叫这个名字；
   用户手工在门户里建的证书名字是别的）
3. 按到期时间排序后**不在最新 N 张之内**（默认保留 2 张）

`--dry-run` 只列不删，用来核对边界是否正确。

## 依赖

只用标准库 + `openssl`（macOS runner 自带）。不装任何 pip 包 ——
这一步是维护动作，不该给发布流程增加依赖。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1/certificates"

# 允许用 OPENSSL 环境变量指定解释器/路径。
# macOS runner 上 openssl 本来就在 PATH 里（默认值即可）；
# 这个开关是为了能在**开发机（Windows）上先本地跑一遍**再让它进 CI ——
# 本项目的原则是"能在本地验证的就别留给 CI 去发现"。
OPENSSL = os.environ.get("OPENSSL", "openssl")


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def der_to_raw(der: bytes) -> bytes:
    """把 DER 编码的 ECDSA 签名转成 JWT 要的 r||s 原始拼接。

    `openssl dgst -sign` 对 ECDSA 一律输出 DER：
        SEQUENCE { INTEGER r, INTEGER s }
    而 JWS ES256 规定签名是 r 和 s 各 32 字节直接拼接（P-256）。
    两个 INTEGER 都是**大端、可能带一个前导 0x00**（最高位为 1 时用来表示正数），
    所以要先剥掉前导零、再左补到 32 字节。
    """
    def read_len(buf: bytes, i: int) -> tuple[int, int]:
        first = buf[i]
        i += 1
        if first & 0x80:
            n = first & 0x7F
            length = 0
            for _ in range(n):
                length = (length << 8) | buf[i]
                i += 1
            return length, i
        return first, i

    if der[0] != 0x30:
        raise ValueError("不是 DER SEQUENCE")
    _, i = read_len(der, 1)

    out = bytearray()
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("不是 DER INTEGER")
        length, i = read_len(der, i + 1)
        value = der[i:i + length]
        i += length
        value = value.lstrip(b"\x00") or b"\x00"
        if len(value) > 32:
            raise ValueError(f"分量过长（{len(value)} 字节），不是 P-256")
        out += b"\x00" * (32 - len(value)) + value
    return bytes(out)


def make_token(key_id: str, issuer: str, key_path: str) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"},
                               separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900,
                                 "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()

    result = subprocess.run(
        [OPENSSL, "dgst", "-sha256", "-sign", key_path],
        input=signing_input, capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError("openssl 签名失败：" + result.stderr.decode(errors="replace"))

    return f"{header}.{payload}.{b64url(der_to_raw(result.stdout))}"


def call(method: str, url: str, token: str) -> dict:
    request = urllib.request.Request(url, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", type=int,
                        default=int(os.environ.get("CERT_KEEP", "2")),
                        help="保留最新几张（默认 2）")
    parser.add_argument("--dry-run", action="store_true", help="只列不删")
    args = parser.parse_args()

    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_KEY_PATH")

    if not (key_id and issuer and key_path):
        print("⚠️ 缺少 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH —— 跳过证书清理")
        return 0
    if not os.path.exists(key_path):
        print(f"⚠️ 找不到密钥文件 {key_path} —— 跳过证书清理")
        return 0

    token = make_token(key_id, issuer, key_path)
    certificates = call("GET", f"{API}?limit=200", token)["data"]
    print(f"账号上共 {len(certificates)} 张证书")

    ci_made = [
        c for c in certificates
        if c["attributes"]["certificateType"] == "DEVELOPMENT"
        and c["attributes"]["displayName"] == "Created via API"
    ]
    print(f"其中属于 CI 产物的：{len(ci_made)} 张（保留最新 {args.keep} 张）")

    # 到期时间 = 创建时间 + 1 年，所以按到期时间升序排列 = 最老的在最前面
    ordered = sorted(ci_made, key=lambda c: (c["attributes"]["expirationDate"], c["id"]))
    doomed = ordered[: max(0, len(ordered) - args.keep)]

    if not doomed:
        print("没有需要吊销的证书 —— 额度充足")
        return 0

    failures = 0
    for certificate in doomed:
        expiration = certificate["attributes"]["expirationDate"][:10]
        if args.dry_run:
            print(f"  [dry-run] 会吊销 {certificate['id']}  到期 {expiration}")
            continue
        try:
            call("DELETE", f"{API}/{certificate['id']}", token)
            print(f"  ✅ 已吊销 {certificate['id']}  到期 {expiration}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:200]
            print(f"  ❌ 失败 {certificate['id']}：HTTP {error.code} {detail}")
            failures += 1

    if args.dry_run:
        return 0

    remaining = call("GET", f"{API}?limit=200", token)["data"]
    print(f"\n吊销 {len(doomed) - failures} 张（失败 {failures}），现在剩 {len(remaining)} 张")
    return 1 if failures else 0


if __name__ == "__main__":
    # ⚠️ 强制 stdout 用 UTF-8：Windows 控制台默认是 GBK，
    # 输出里的 emoji / 中文会直接抛 UnicodeEncodeError ——
    # 而且**恰好会在"正要报错"的时候再抛一个错**，把真正的错误盖掉。
    # macOS runner 上本来就是 UTF-8，这行主要是为了能在开发机上先本地验证。
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001
        # 这一步是**维护动作**，不该把发布拖下水 —— 出错就如实报出来然后放行。
        # 调用方（workflow）另外还给了 continue-on-error，双保险。
        print(f"⚠️ 证书清理失败（不影响发布）：{error}")
        sys.exit(0)
