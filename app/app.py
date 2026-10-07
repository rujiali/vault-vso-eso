#!/usr/bin/env python3
"""ESO vs VSO demo app. Standard library only, so it runs on a stock python image
with no build step (mounted from a ConfigMap) — nothing to mirror except python:3.12-alpine.

  python app.py workload    The "application". Reads its secrets ONCE at start-up, the way
                            most real apps do (env vars + a TLS cert file), and reports what
                            it is using on /state. Every 10s it also tries to log in to
                            Postgres with the credential it started with, so a credential
                            that Vault has expired or revoked shows up as a real failure.

  python app.py dashboard   The side-by-side view. Every second it compares what is in each
                            Kubernetes Secret with what each app is actually using, and times
                            how long rotations take to reach each.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import socket
import ssl
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
STARTED = time.time()


def cert_info(pem):
    """Serial (last 8 hex) and notAfter (epoch) of the first certificate in a PEM string."""
    if not pem or "-----BEGIN CERTIFICATE-----" not in pem:
        return None
    start = pem.index("-----BEGIN CERTIFICATE-----")
    end = pem.index("-----END CERTIFICATE-----", start) + len("-----END CERTIFICATE-----")
    fd, path = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(pem[start:end] + "\n")
        d = ssl._ssl._test_decode_cert(path)  # stdlib X.509 parser; fine for a lab
        return {"serial": d.get("serialNumber", "")[-8:], "not_after": ssl.cert_time_to_seconds(d["notAfter"])}
    except Exception:
        return None
    finally:
        os.unlink(path)


# ---------------------------------------------------------------------------
# Postgres login check (wire protocol + SCRAM-SHA-256, standard library only)
# ---------------------------------------------------------------------------
def _pg_msgs(sock):
    """Yield (type, body) protocol messages from the server."""
    buf = b""
    while True:
        while len(buf) < 5:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed the connection")
            buf += chunk
        typ, length = buf[:1], struct.unpack("!I", buf[1:5])[0]
        while len(buf) < 1 + length:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed the connection")
            buf += chunk
        yield typ, buf[5:1 + length]
        buf = buf[1 + length:]


def _pg_error(body):
    fields = dict((f[:1], f[1:].decode(errors="replace")) for f in body.split(b"\0") if f)
    return fields.get(b"M", "login failed")


class PgError(Exception):
    pass


def _pg_auth(sock, user, password, database):
    """Run startup + authentication on an open socket. Returns the message stream once
    authenticated. Raises PgError with Postgres's own message on failure.
    Supports SCRAM-SHA-256, MD5 and cleartext."""
    params = b"user\0" + user.encode() + b"\0database\0" + database.encode() + b"\0\0"
    sock.sendall(struct.pack("!II", 8 + len(params), 196608) + params)
    msgs = _pg_msgs(sock)
    nonce = client_first_bare = None
    for typ, body in msgs:
        if typ == b"E":
            raise PgError(_pg_error(body))
        if typ != b"R":
            continue
        code = struct.unpack("!I", body[:4])[0]
        if code == 0:  # AuthenticationOk
            return msgs
        if code == 3:  # cleartext
            pw = password.encode() + b"\0"
            sock.sendall(b"p" + struct.pack("!I", 4 + len(pw)) + pw)
        elif code == 5:  # md5
            salt = body[4:8]
            inner = hashlib.md5(password.encode() + user.encode()).hexdigest().encode()
            pw = b"md5" + hashlib.md5(inner + salt).hexdigest().encode() + b"\0"
            sock.sendall(b"p" + struct.pack("!I", 4 + len(pw)) + pw)
        elif code == 10:  # SASL: start SCRAM-SHA-256
            nonce = base64.b64encode(os.urandom(18)).decode()
            client_first_bare = "n=,r=" + nonce
            first = ("n,," + client_first_bare).encode()
            payload = b"SCRAM-SHA-256\0" + struct.pack("!I", len(first)) + first
            sock.sendall(b"p" + struct.pack("!I", 4 + len(payload)) + payload)
        elif code == 11:  # SASL continue: server-first
            server_first = body[4:].decode()
            attrs = dict(kv.split("=", 1) for kv in server_first.split(","))
            if not attrs["r"].startswith(nonce):
                raise PgError("SCRAM nonce mismatch")
            salted = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(attrs["s"]), int(attrs["i"]))
            client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
            stored_key = hashlib.sha256(client_key).digest()
            without_proof = "c=biws,r=" + attrs["r"]
            auth_message = ",".join([client_first_bare, server_first, without_proof]).encode()
            signature = hmac.new(stored_key, auth_message, hashlib.sha256).digest()
            proof = bytes(a ^ b for a, b in zip(client_key, signature))
            final = (without_proof + ",p=" + base64.b64encode(proof).decode()).encode()
            sock.sendall(b"p" + struct.pack("!I", 4 + len(final)) + final)
        elif code == 12:  # SASL final; AuthenticationOk follows
            continue
        else:
            raise PgError(f"unsupported auth method {code}")
    raise PgError("no response")


def pg_login(host, port, user, password, database="demo", timeout=3.0):
    """Try to authenticate. Returns (ok, message)."""
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        _pg_auth(sock, user, password, database)
        sock.sendall(b"X\0\0\0\4")
        return True, "login OK"
    except PgError as e:
        return False, str(e)
    finally:
        sock.close()


def pg_query(host, port, user, password, sql, database="demo", timeout=3.0):
    """Run one simple query. Returns a list of rows (tuples of str or None)."""
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        msgs = _pg_auth(sock, user, password, database)
        for typ, body in msgs:  # wait until the server is ready for a query
            if typ == b"E":
                raise PgError(_pg_error(body))
            if typ == b"Z":
                break
        q = sql.encode() + b"\0"
        sock.sendall(b"Q" + struct.pack("!I", 4 + len(q)) + q)
        rows = []
        for typ, body in msgs:
            if typ == b"E":
                raise PgError(_pg_error(body))
            if typ == b"D":
                n = struct.unpack("!H", body[:2])[0]
                pos, row = 2, []
                for _ in range(n):
                    ln = struct.unpack("!i", body[pos:pos + 4])[0]
                    pos += 4
                    if ln < 0:
                        row.append(None)
                    else:
                        row.append(body[pos:pos + ln].decode(errors="replace"))
                        pos += ln
                rows.append(tuple(row))
            elif typ == b"Z":
                break
        sock.sendall(b"X\0\0\0\4")
        return rows
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# workload
# ---------------------------------------------------------------------------
def run_workload():
    tls = None
    try:
        with open("/tls/tls.crt") as f:
            tls = cert_info(f.read())
    except OSError:
        pass
    user = os.environ.get("DB_USERNAME")
    password = os.environ.get("DB_PASSWORD")
    db_host = os.environ.get("DB_HOST", "postgres.db.svc.cluster.local")
    state = {
        "side": os.environ.get("SIDE", "?"),
        "pod": os.environ.get("POD_NAME", "?"),
        "started": STARTED,
        "message": os.environ.get("APP_MESSAGE"),
        "db_username": user,
        "tls": tls,
        "db_login": None,
    }
    lock = threading.Lock()

    def check_db():
        # Log in with the credential this pod started with, every 10s, like an app opening connections.
        while True:
            if user and password:
                try:
                    ok, msg = pg_login(db_host, 5432, user, password)
                except Exception as e:  # noqa: BLE001
                    ok, msg = False, f"cannot reach Postgres: {e}"
                with lock:
                    state["db_login"] = {"ok": ok, "message": msg, "at": time.time()}
            time.sleep(10)

    threading.Thread(target=check_db, daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            with lock:
                body = json.dumps(state).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    print(f"workload {state['side']} serving on :{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), H).serve_forever()


# ---------------------------------------------------------------------------
# dashboard
# ---------------------------------------------------------------------------
SIDES = [("vso", "app-vso"), ("eso", "app-eso")]
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
ROTATED = re.compile(r"^rotated-(\d+)$")


class Tracker:
    """Remembers when the dashboard first saw each value, to time rotations."""

    def __init__(self):
        self.seen = {}

    def first_seen(self, key, value):
        prev = self.seen.get(key)
        if prev is None or prev[0] != value:
            self.seen[key] = (value, time.time())
        return self.seen[key][1]


def k8s_secret(ns, name):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    req = urllib.request.Request(
        f"https://{host}:{port}/api/v1/namespaces/{ns}/secrets/{name}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=3) as r:
            data = json.load(r).get("data") or {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return {k: base64.b64decode(v).decode(errors="replace") for k, v in data.items()}


def app_state(ns):
    try:
        with urllib.request.urlopen(f"http://app.{ns}.svc.cluster.local:8080/state", timeout=2) as r:
            return json.load(r)
    except Exception:
        return None


DB_USERS_SQL = ("select rolname, case when rolvaliduntil is null or rolvaliduntil = 'infinity' then null "
                "else extract(epoch from rolvaliduntil)::bigint end from pg_roles "
                "where rolname like 'v-app-%' order by rolvaliduntil")
_db_cache = {"at": 0, "value": None}


def live_db_users():
    """Live Vault-issued Postgres users per side, read by a read-only monitoring login."""
    if time.time() - _db_cache["at"] < 3:
        return _db_cache["value"]
    pw = os.environ.get("PG_MONITOR_PASSWORD")
    if not pw:
        value = {"error": "no monitoring login configured"}
    else:
        try:
            rows = pg_query(os.environ.get("DB_HOST", "postgres.db.svc.cluster.local"), 5432,
                            os.environ.get("PG_MONITOR_USER", "demo_monitor"), pw, DB_USERS_SQL)
            value = {"vso": [], "eso": []}
            for name, exp in rows:
                side = "vso" if name.startswith("v-app-vso-") else "eso" if name.startswith("v-app-eso-") else None
                if side:
                    value[side].append({"name": name, "expires": int(exp) if exp else None})
        except Exception as e:  # noqa: BLE001
            value = {"error": f"Postgres: {e}"}
    _db_cache.update(at=time.time(), value=value)
    return value


def collect(tracker):
    now = time.time()
    out = {"now": now, "sides": {}}
    for side, ns in SIDES:
        s = {"error": None}
        try:
            cfg = k8s_secret(ns, "app-config")
            db = k8s_secret(ns, "db-creds")
            tls = k8s_secret(ns, "app-tls")
        except Exception as e:  # noqa: BLE001
            cfg = db = tls = None
            s["error"] = f"Kubernetes API: {e}"
        app = app_state(ns)

        # KV — time how long a rotation takes to reach the Secret and the running app
        sec_msg = (cfg or {}).get("message")
        app_msg = (app or {}).get("message")
        kv = {"secret": sec_msg, "app": app_msg, "rotated_at": None, "secret_latency": None, "app_latency": None}
        m = ROTATED.match(sec_msg or "")
        if m:
            rotated_at = int(m.group(1))
            kv["rotated_at"] = rotated_at
            if rotated_at >= STARTED - 2:  # only time rotations the dashboard was watching
                kv["secret_latency"] = max(0.0, tracker.first_seen(f"{side}/kv/secret", sec_msg) - rotated_at)
                if app_msg == sec_msg:
                    kv["app_latency"] = max(0.0, tracker.first_seen(f"{side}/kv/app", app_msg) - rotated_at)
        if app_msg:
            tracker.first_seen(f"{side}/kv/app", app_msg)
        if sec_msg:
            tracker.first_seen(f"{side}/kv/secret", sec_msg)

        # DB credential
        sec_user = (db or {}).get("username")
        dbv = {"secret": sec_user, "app": (app or {}).get("db_username"), "secret_changed": None,
               "login": (app or {}).get("db_login")}
        if sec_user:
            t = tracker.first_seen(f"{side}/db/secret", sec_user)
            dbv["secret_changed"] = t if t > STARTED + 2 else None

        # TLS certificate
        tlsv = {"secret": cert_info((tls or {}).get("tls.crt")), "app": (app or {}).get("tls")}

        users = live_db_users() or {}
        s["dbusers"] = {
            "error": users.get("error"),
            "users": users.get(side, []),
            "secret_user": sec_user,
            "app_user": (app or {}).get("db_username"),
        }
        s.update({
            "kv": kv,
            "db": dbv,
            "tls": tlsv,
            "pod": {"name": app.get("pod"), "started": app.get("started")} if app else None,
        })
        out["sides"][side] = s

    # Both sides read the same Vault secret. If one side's Secret carries a newer rotation
    # than the other's, the lagging side hasn't picked the change up yet.
    rotations = [v["kv"]["rotated_at"] for v in out["sides"].values() if v.get("kv") and v["kv"].get("rotated_at")]
    newest = max(rotations) if rotations else None
    for v in out["sides"].values():
        kv = v.get("kv") or {}
        if newest and (kv.get("rotated_at") or 0) < newest:
            kv["behind_since"] = newest
    return out


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESO vs VSO</title>
<style>
:root{--bg:#f5f6f8;--card:#fff;--ink:#15171c;--muted:#5d6572;--line:#e2e5ea;
--ok:#11703a;--okbg:#e3f3ea;--warn:#7d5200;--warnbg:#fcefd2;--bad:#a1161b;--badbg:#fbe2e2;--idle:#5d6572;--idlebg:#eceef2;
--vso:#6b3fd4;--eso:#1f6fb2}
@media (prefers-color-scheme:dark){:root{--bg:#0e1014;--card:#161920;--ink:#e7e9ee;--muted:#98a0ad;--line:#272c36;
--ok:#63d392;--okbg:#10301e;--warn:#f1b84d;--warnbg:#33260c;--bad:#ff8083;--badbg:#3b1517;--idle:#98a0ad;--idlebg:#20242c;
--vso:#a88bff;--eso:#6db3f2}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif}
main{max-width:1280px;margin:0 auto;padding:28px 24px 40px}
header{display:flex;justify-content:space-between;align-items:baseline;gap:16px;margin-bottom:20px}
h1{font-size:22px;margin:0;font-weight:650;letter-spacing:-.01em}
.clock{color:var(--muted);font-variant-numeric:tabular-nums}
.grid{display:grid;grid-template-columns:170px 1fr 1fr;gap:12px}
.colhead{font-weight:650;font-size:18px;padding:4px 4px 0}
.colhead small{display:block;font-weight:400;color:var(--muted);font-size:14px}
.colhead.vso{border-top:4px solid var(--vso);padding-top:10px}
.colhead.eso{border-top:4px solid var(--eso);padding-top:10px}
.rowhead{font-weight:600;padding:16px 4px;color:var(--muted);font-size:15px}
.cell{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;min-height:112px}
.line{display:flex;gap:10px;align-items:baseline}
.k{width:62px;flex:none;color:var(--muted);font-size:13px;text-transform:uppercase;letter-spacing:.04em}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:15px;word-break:break-all}
.badge{display:inline-block;margin-top:10px;padding:2px 10px;border-radius:999px;font-size:13px;font-weight:600}
.ok{color:var(--ok);background:var(--okbg)} .warn{color:var(--warn);background:var(--warnbg)}
.bad{color:var(--bad);background:var(--badbg)} .idle{color:var(--idle);background:var(--idlebg)}
.note{margin-top:8px;font-size:14px;color:var(--muted);font-variant-numeric:tabular-nums}
.note b{color:var(--ink)}
.err{color:var(--bad);font-size:14px;margin-top:6px}
@media (max-width:760px){.grid{grid-template-columns:1fr}.rowhead{padding:12px 0 0}.colhead{display:none}
.cell::before{content:attr(data-side);display:block;font-size:12px;font-weight:700;color:var(--muted);margin-bottom:6px}}
</style></head>
<body><main>
<header><h1>Same Vault, same app — two operators</h1><span class="clock" id="clock"></span></header>
<div class="grid" id="grid"></div>
</main>
<script>
const ROWS=[["kv","Static secret<br>(KV v2)"],["db","Database<br>credential"],["dbusers","Live users<br>in Postgres"],["tls","TLS<br>certificate"],["pod","App pod"]];
const SIDES=[["vso","VSO","Vault Secrets Operator"],["eso","ESO","External Secrets Operator"]];
let skew=0;
const esc=s=>String(s??"—").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const now=()=>Date.now()/1000+skew;
function dur(s){s=Math.round(s);const neg=s<0;s=Math.abs(s);const t=s<60?s+"s":s<3600?Math.floor(s/60)+"m "+String(s%60).padStart(2,"0")+"s":Math.floor(s/3600)+"h "+String(Math.floor(s%3600/60)).padStart(2,"0")+"m";return neg?"-"+t:t}
const badge=(c,t)=>`<span class="badge ${c}">${t}</span>`;
const line=(k,v)=>`<div class="line"><span class="k">${k}</span><span class="mono">${v}</span></div>`;

function kv(d){
  let h=line("Secret",esc(d.secret))+line("App",esc(d.app));
  if(!d.secret) return h+badge("idle","not synced yet");
  if(d.behind_since) return h+badge("warn","Secret not updated yet")+`<div class="note">Vault changed <b>${dur(now()-d.behind_since)}</b> ago, still waiting for this operator</div>`;
  if(!d.app) return h+badge("idle","app not running");
  if(d.secret===d.app) h+=badge("ok","in sync"); else h+=badge("warn","app on old value");
  let n=[];
  if(d.secret_latency!=null) n.push(`Secret updated <b>${dur(d.secret_latency)}</b> after rotation`);
  else if(d.rotated_at) n.push(`waiting for sync — <b>${dur(now()-d.rotated_at)}</b> since rotation`);
  if(d.app_latency!=null) n.push(`app on new value after <b>${dur(d.app_latency)}</b>`);
  else if(d.secret_latency!=null && d.secret!==d.app) n.push(`app still on old value — <b>${dur(now()-d.rotated_at)}</b>`);
  return h+(n.length?`<div class="note">${n.join(" · ")}</div>`:"");
}
function db(d){
  let h=line("Secret",esc(d.secret))+line("App",esc(d.app));
  if(d.login) h+=line("Login", d.login.ok ? "OK" : "<b style='color:var(--bad)'>FAILED</b> · "+esc(d.login.message));
  if(!d.secret) return h+badge("idle","no credential");
  if(!d.app) return h+badge("idle","app not running");
  if(d.login && !d.login.ok) h+=badge("bad","app can't log in to Postgres");
  else h+= d.secret===d.app ? badge("ok","in sync") : badge("warn","app on old credential");
  if(d.secret_changed) h+=`<div class="note">credential changed <b>${dur(now()-d.secret_changed)}</b> ago</div>`;
  return h;
}
function dbusers(d){
  if(!d) return line("Users","—");
  if(d.error) return line("Users","—")+`<div class="err">${esc(d.error)}</div>`;
  const u=d.users||[];
  let h=line("Live",`<b>${u.length}</b> user${u.length===1?"":"s"}`);
  for(const x of u.slice(0,4)){
    const tags=[]; if(x.name===d.secret_user) tags.push("Secret"); if(x.name===d.app_user) tags.push("app");
    const left=x.expires? x.expires-now() : null;
    h+=line("",`${esc(x.name)} · ${left===null?"no expiry":left>0?"expires in "+dur(left):"expired"}${tags.length?" · <b>"+tags.join(" + ")+"</b>":""}`);
  }
  if(u.length>4) h+=`<div class="note">+${u.length-4} more</div>`;
  if(!d.secret_user) return h+(u.length ? badge("bad","still valid, nothing tracking them") : badge("ok","none left: revoked"));
  const unused=u.filter(x=>x.name!==d.secret_user && x.name!==d.app_user).length;
  if(unused) h+=badge("warn",`${unused} not in use, left to expire`);
  return h;
}
function certTxt(c){ if(!c) return "—"; const left=c.not_after-now();
  return `${esc(c.serial)} · ${left>0?"expires in "+dur(left):"<b style='color:var(--bad)'>EXPIRED "+dur(-left)+" ago</b>"}`; }
function tls(d){
  let h=line("Secret",certTxt(d.secret))+line("App",certTxt(d.app));
  if(!d.secret) return h+badge("idle","no certificate");
  if(!d.app) return h+badge("idle","app not running");
  if(d.app.not_after<now()) return h+badge("bad","app serving an expired cert");
  return h+(d.secret.serial===d.app.serial?badge("ok","in sync"):badge("warn","app on old cert"));
}
function pod(d){
  if(!d) return line("Pod","—")+badge("idle","not running");
  return line("Pod",esc(d.name))+`<div class="note">started <b>${dur(now()-d.started)}</b> ago</div>`;
}
const R={kv,db,dbusers,tls,pod};

function render(st){
  let h=`<div></div>`+SIDES.map(([k,a,b])=>`<div class="colhead ${k}">${a}<small>${b}</small></div>`).join("");
  for(const [key,label] of ROWS){
    h+=`<div class="rowhead">${label}</div>`;
    for(const [side,abbr] of SIDES){
      const s=st.sides[side]||{}; let body;
      try{ body=R[key](s[key]??(key==="pod"?null:{})); }catch(e){ body="—"; }
      if(key==="kv"&&s.error) body+=`<div class="err">${esc(s.error)}</div>`;
      h+=`<div class="cell" data-side="${abbr}">${body}</div>`;
    }
  }
  document.getElementById("grid").innerHTML=h;
  document.getElementById("clock").textContent=new Date(now()*1000).toLocaleTimeString();
}
let last=null;
async function tick(){
  try{ const r=await fetch("api/state",{cache:"no-store"}); last=await r.json(); skew=last.now-Date.now()/1000; }catch(e){}
  if(last) render(last);
}
tick(); setInterval(tick,1000);
</script>
</body></html>
"""


def run_dashboard():
    tracker = Tracker()
    snapshot = {"now": time.time(), "sides": {}}
    lock = threading.Lock()

    def loop():
        nonlocal snapshot
        while True:
            try:
                s = collect(tracker)
                with lock:
                    snapshot = s
            except Exception as e:  # noqa: BLE001
                print(f"collect failed: {e}", file=sys.stderr, flush=True)
            time.sleep(1)

    threading.Thread(target=loop, daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, body, ctype):
            b = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path.startswith("/api/state"):
                with lock:
                    self._send(json.dumps(snapshot), "application/json")
            else:
                self._send(PAGE, "text/html; charset=utf-8")

    print(f"dashboard serving on :{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), H).serve_forever()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "workload"
    run_dashboard() if mode == "dashboard" else run_workload()
