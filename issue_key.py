#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发码工具：生成授权码，写进签名配置，推送生效。

用法（一般的用法就第一条）：

    python issue_key.py --days 7 --sub 202608140075 --note "张三" --push
    python issue_key.py --plan forever --sub 202608140075 --push
    python issue_key.py --plan 30d --sub 202608140075 --push
    python issue_key.py --revoke K7M2Q-9XB3T-VRD8N-HW4PJ-6CYZF --push
    python issue_key.py --list
    python issue_key.py --prune --push

设计要点：

* **配置里只写指纹（kid），不写码**。仓库是公开的，写明文等于把码贴在墙上。
  指纹 = sha256(规范化后的码) 前 16 位，反推不出码。
* 明文只出现在终端和本地 `_keys.txt`（不入库），丢了就只能重新发一个。
* 每次改完都会重新签名并（加 --push 时）推送 + 清 jsDelivr 缓存。
"""

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from sign_gate import canonical, load_key  # noqa: E402

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"  # Crockford：无 I L O U
KEY_LEN = 25
GROUP = 5
APP = "jwhelper"
DEFAULT_FILE = HERE / "kq_gate.json"
LEDGER = HERE / "_keys.txt"
LICENCE_FEATURES = ["autoSign", "manualSign", "forceSign"]

# 黄金向量：和 Dart 侧 test/features/attendance/licence_key_test.dart 一致
GOLDEN_KEY = "K7M2Q9XB3TVRD8NHW4PJ6CYZF"
GOLDEN_KID = "2FA266553D7EAEBA"


# --------------------------------------------------------------------- 算法

def normalize(raw):
    """规整成人手抄进来也能认的形态；不像个码返回 None。"""
    out = []
    for ch in (raw or "").upper():
        if ch in " -_\t\r\n":
            continue
        if ch == "O":
            ch = "0"
        elif ch in "IL":
            ch = "1"
        if ch not in ALPHABET:
            return None
        out.append(ch)
    s = "".join(out)
    return s if len(s) == KEY_LEN else None


def kid_of(normalized):
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16].upper()


def gen_key():
    return "".join(secrets.choice(ALPHABET) for _ in range(KEY_LEN))


def fmt(key):
    return "-".join(key[i:i + GROUP] for i in range(0, len(key), GROUP))


# ------------------------------------------------------------------- 配置文件

def load_doc(path):
    if path.exists():
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            sys.exit("现有配置读不出来：%s" % e)
        doc.pop("sig", None)
        return doc
    return {}


def app_section(doc):
    apps = doc.setdefault("apps", {})
    me = apps.setdefault(APP, {})
    me.setdefault("killAll", False)
    me.setdefault("features", {"autoSign": True, "manualSign": True})
    me.setdefault("licence", {"required": True, "features": LICENCE_FEATURES})
    me.setdefault("licences", [])
    return me


def sign_and_write(doc, path, expires_days=1095):
    doc["v"] = 2
    now = datetime.now(timezone.utc).replace(microsecond=0)
    doc["issuedAt"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    doc["expiresAt"] = (now + timedelta(days=expires_days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    key = load_key()
    sig = key.sign(canonical(doc).encode("utf-8")).signature
    import base64
    doc["sig"] = base64.b64encode(sig).decode("ascii")
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def push(path):
    """推送到 GitHub 并清 CDN 缓存（复用 push_files.py）。"""
    script = HERE / "push_files.py"
    if not script.exists():
        print("！ 找不到 push_files.py，跳过推送；记得手动推 %s" % path.name)
        return
    env = dict(os.environ)
    token = env.get("GH_TOKEN", "").strip()
    if not token:
        token_file = HERE / ".gh_token"
        if token_file.exists():
            env["GH_TOKEN"] = token_file.read_text(encoding="utf-8").strip()
    r = subprocess.run(
        [sys.executable, str(script), path.name],
        cwd=str(HERE), env=env, capture_output=True, text=True,
    )
    for line in (r.stdout + r.stderr).strip().splitlines()[-6:]:
        print("   ", line)


# ------------------------------------------------------------------- 命令

def cmd_issue(a):
    path = Path(a.file)
    doc = load_doc(path)
    me = app_section(doc)

    days = 0
    if a.plan:
        p = a.plan.strip().lower()
        if p in ("forever", "perm", "永久", "0"):
            days = 0
        elif p.endswith("d") and p[:-1].isdigit():
            days = int(p[:-1])
        elif p.isdigit():
            days = int(p)
        else:
            sys.exit("认不出的期限：%s（用 7d / 30d / forever / 数字天数）" % a.plan)
    elif a.days is not None:
        days = a.days

    sub = (a.sub or "").strip()
    if not sub:
        sys.exit("必须指定学号：--sub 202608140075（一个码只认一个学号）")
    if sub == "*" and not a.allow_any:
        sys.exit("不允许发不限学号的码；真要测试请显式加 --allow-any")

    made = []
    for _ in range(max(1, a.count)):
        key = gen_key()
        kid = kid_of(key)
        record = {
            "kid": kid,
            "days": days,
            "sub": sub,
            "iat": datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        if a.strict:
            record["strict"] = True
        if a.note:
            record["note"] = a.note
        me["licences"].append(record)
        made.append((key, kid, record))

    sign_and_write(doc, path)

    plan_text = "永久（不会到期）" if days == 0 else "%d 天（从第一次激活开始算）" % days
    for key, kid, record in made:
        print()
        print("────────────────────────────────────────────")
        print(" 授权码   %s" % fmt(key))
        print(" 期限     %s" % plan_text)
        print(" 学号     %s" % sub)
        if a.note:
            print(" 备注     %s" % a.note)
        print(" 指纹     %s" % kid)
        print("────────────────────────────────────────────")
        with LEDGER.open("a", encoding="utf-8") as f:
            f.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (
                datetime.now().strftime("%Y-%m-%d %H:%M"),
                "forever" if days == 0 else "%dd" % days,
                sub, a.note or "", kid, key,
            ))

    print()
    if a.push:
        print("正在推送…")
        push(path)
        print("已生效：对方在 App 里输码即可（最多等一个回源周期）。")
    else:
        print("配置已写入 %s，但**还没推送**。加 --push 才会生效。" % path.name)
    print("明文也记在 %s（不入库，别删）。" % LEDGER)


def cmd_revoke(a):
    path = Path(a.file)
    doc = load_doc(path)
    me = app_section(doc)
    raw = (a.revoke or "").strip()
    norm = normalize(raw)
    kid = kid_of(norm) if norm else raw.upper()
    before = len(me["licences"])
    kept = [r for r in me["licences"] if str(r.get("kid", "")).upper() != kid]
    if len(kept) == before:
        sys.exit("名单里没有这个指纹：%s" % kid)
    me["licences"] = kept
    sign_and_write(doc, path)
    print("已作废 %s（剩 %d 条有效码）" % (kid, len(kept)))
    if a.push:
        push(path)


def cmd_list(a):
    path = Path(a.file)
    doc = load_doc(path)
    me = app_section(doc)
    rows = me["licences"]
    if not rows:
        print("还没有发过码。")
        return
    now = datetime.now(timezone.utc)
    print("%-18s %-9s %-14s %-12s %s" % ("指纹", "期限", "学号", "状态", "备注"))
    for r in rows:
        days = int(r.get("days", 0))
        if days <= 0:
            plan, state = "永久", "有效"
        else:
            plan = "%dd" % days
            iat = r.get("iat") or ""
            if r.get("strict") and iat:
                exp = datetime.strptime(iat[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc) + timedelta(days=days)
                state = "有效" if now < exp else "已过期"
            else:
                state = "看激活时间"
        print("%-18s %-9s %-14s %-12s %s" % (
            r.get("kid", ""), plan, r.get("sub", "*"), state, r.get("note", ""),
        ))


def cmd_prune(a):
    path = Path(a.file)
    doc = load_doc(path)
    me = app_section(doc)
    now = datetime.now(timezone.utc)
    kept, dropped = [], 0
    for r in me["licences"]:
        days = int(r.get("days", 0))
        iat = r.get("iat") or ""
        if days > 0 and r.get("strict") and iat:
            exp = datetime.strptime(iat[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc) + timedelta(days=days)
            if now >= exp:
                dropped += 1
                continue
        kept.append(r)
    if dropped == 0:
        print("没有需要清理的记录。")
        return
    me["licences"] = kept
    sign_and_write(doc, path)
    print("清掉 %d 条已过期的记录，剩 %d 条。" % (dropped, len(kept)))
    if a.push:
        push(path)


def cmd_self_test():
    ok = True

    def check(name, cond):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + name)
        ok = ok and cond

    check("黄金向量", kid_of(normalize(GOLDEN_KEY)) == GOLDEN_KID)
    check("小写+横杠", normalize("k7m2q-9xb3t-vrd8n-hw4pj-6cyzf") == GOLDEN_KEY)
    check("空格", normalize(" K7M2Q 9XB3T VRD8N HW4PJ 6CYZF ") == GOLDEN_KEY)
    check("O→0", normalize("K7M2Q9XB3TVRD8NHW4PJ6CYZO").endswith("0"))
    check("I→1", normalize("K7M2Q9XB3TVRD8NHW4PJ6CYZI").endswith("1"))
    check("太短无效", normalize("K7M2Q") is None)
    check("含 U 无效", normalize("K7M2Q9XB3TVRD8NHW4PJ6CYZU") is None)
    k = gen_key()
    check("生成的码能被自己认出来", normalize(fmt(k)) == k)
    print("ALL PASS" if ok else "有失败项")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(DEFAULT_FILE))
    ap.add_argument("--plan", default="")
    ap.add_argument("--days", type=int, default=None)
    ap.add_argument("--sub", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--strict", action="store_true",
                    help="起算点钉在发码那天（重装也不会重新计时）")
    ap.add_argument("--allow-any", action="store_true",
                    help="允许 sub=*（不限学号），只给自己测试用")
    ap.add_argument("--revoke", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--push", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        return cmd_self_test()
    if a.list:
        return cmd_list(a)
    if a.revoke:
        return cmd_revoke(a)
    if a.prune:
        return cmd_prune(a)
    return cmd_issue(a)


if __name__ == "__main__":
    sys.exit(main())
