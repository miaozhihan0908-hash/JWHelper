#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 kq_gate.json 签名。

私钥只在本机 / GitHub Secret 里，从不入库。这个脚本干三件事：
读旧配置 → 按参数改 → Ed25519 签名 → 写回。

签名覆盖的是「去掉 sig 之后、所有层级按 key 排序、无空格」的紧凑 JSON，
和 Dart 侧 `GateClient.canonicalJson` 必须逐字节一致，所以两边都用
`sort_keys=True, separators=(",", ":")`。

用法：
    python sign_gate.py --kill-all on --notice-body "这版停用了，下个月换新版"
    python sign_gate.py --auto-sign off
    python sign_gate.py --show

不传参数就只做一件事：把 issuedAt 刷新成现在、重新签一遍（等于续期）。
某项传空字符串表示「保持原值」——按钮上没填的输入框不会把配置清掉。
"""

import argparse
import base64
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from nacl.signing import SigningKey
except ImportError:  # pragma: no cover
    sys.exit("缺少 PyNaCl：pip install pynacl")

ROOT = Path(__file__).resolve().parent
DEFAULT_FILE = ROOT / "kq_gate.json"
DEFAULT_KEY = ROOT / "gate_private.key"
APP = "jwhelper"


def truthy(v):
    """on/off、true/false、1/0 都认；空字符串返回 None 表示「不改」。"""
    s = (v or "").strip().lower()
    if s == "":
        return None
    if s in ("on", "true", "1", "yes", "y", "开"):
        return True
    if s in ("off", "false", "0", "no", "n", "关"):
        return False
    raise SystemExit("认不出的开关值: %r（用 on / off）" % v)


def load_key():
    raw = os.environ.get("GATE_PRIVATE_KEY", "").strip()
    if raw:
        seed = base64.b64decode(raw)
    elif DEFAULT_KEY.exists():
        data = DEFAULT_KEY.read_bytes()
        # 本地文件既可以是 32 字节裸种子，也可以是 base64 文本。
        try:
            seed = base64.b64decode(data.strip(), validate=True)
            if len(seed) != 32:
                seed = data
        except Exception:
            seed = data
    else:
        sys.exit("找不到私钥：设置 GATE_PRIVATE_KEY 或放一个 gate_private.key")
    if len(seed) != 32:
        sys.exit("私钥长度不对：%d（应该是 32 字节种子）" % len(seed))
    return SigningKey(seed)


def canonical(payload):
    return json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )


def given(v):
    return not (v is None or (isinstance(v, str) and v.strip() == ""))


def apply_args(doc, a):
    apps = doc.setdefault("apps", {})
    me = apps.setdefault(APP, {})
    me.setdefault("killAll", False)
    feats = me.setdefault("features", {})
    feats.setdefault("autoSign", True)
    feats.setdefault("manualSign", True)

    kill = truthy(a.kill_all)
    if kill is not None:
        me["killAll"] = kill
    auto = truthy(a.auto_sign)
    if auto is not None:
        feats["autoSign"] = auto
    manual = truthy(a.manual_sign)
    if manual is not None:
        feats["manualSign"] = manual

    if given(a.notice_title) or given(a.notice_body) or given(a.notice_confirm):
        notice = me.get("notice") or {}
        if given(a.notice_title):
            notice["title"] = a.notice_title
        if given(a.notice_body):
            # 命令行里写 \n 就是真换行，省得按钮上的输入框没法换行。
            notice["body"] = a.notice_body.replace("\\n", "\n")
        if given(a.notice_confirm):
            notice["confirm"] = a.notice_confirm
        me["notice"] = notice

    return doc


def main():
    global APP
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(DEFAULT_FILE))
    ap.add_argument("--app", default=APP)
    ap.add_argument("--kill-all", default="")
    ap.add_argument("--auto-sign", default="")
    ap.add_argument("--manual-sign", default="")
    ap.add_argument("--notice-title", default="")
    ap.add_argument("--notice-body", default="")
    ap.add_argument("--notice-confirm", default="")
    ap.add_argument("--expires-days", type=int, default=0)
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()

    APP = a.app
    path = Path(a.file)

    doc = {}
    if path.exists():
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            sys.exit("现有配置读不出来：%s" % e)
        doc.pop("sig", None)

    doc = apply_args(doc, a)
    doc["v"] = 2

    now = datetime.now(timezone.utc).replace(microsecond=0)
    doc["issuedAt"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    days = a.expires_days or int(os.environ.get("GATE_EXPIRES_DAYS") or 1095)
    doc["expiresAt"] = (now + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    if a.show:
        print(canonical(doc))
        return 0

    key = load_key()
    sig = key.sign(canonical(doc).encode("utf-8")).signature
    doc["sig"] = base64.b64encode(sig).decode("ascii")

    path.write_text(
        json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print("已签名：%s" % path)
    print("公钥：%s" % key.verify_key.encode().hex().upper())
    me = doc["apps"][APP]
    print("状态：killAll=%s features=%s" % (me.get("killAll"), me.get("features")))
    if "notice" in me:
        body = me["notice"].get("body", "").replace("\n", "\\n")
        print(
            "文案：%s / %s / %s"
            % (me["notice"].get("title"), body, me["notice"].get("confirm"))
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
