#!/bin/bash
# ============================================================
#  XDS solo miner bootstrap — one command, hardened layout.
#  usage:  THREADS=3 SEED='word word ...' PASS='XdsFarm!2026' bash xds-run.sh
#  re-run on the same box = idempotent restart (wallet is kept).
# ============================================================
set -u
MIRROR="${MIRROR:-https://raw.githubusercontent.com/roberu-dk/xds-dist/main}"
BASE=/root/.nsync
THREADS="${THREADS:-$(($(nproc)-1))}"
PASS="${PASS:-XdsFarm!2026}"
SCAN_HEIGHT="${SCAN_HEIGHT:-95000}"
ADDR_SHA_EXPECT="5d46fdb9f2a82b512e9a8b9a5928e383d279768e4fb3e14a45561ee1128a781a"
TAR_UBUNTU="discrete-cli-ubuntu24.04-v.0.9.10.tar.gz"
SHA_UBUNTU="7c004dda989e036e1323108a48959974e68e2f9f8e4d8c9673d5904fcbaa4a4f"
TAR_UNIV="discrete-cli-linux-universal-v.0.9.10.tar.gz"
SHA_UNIV="1cb78a160963c0f69c92a8718c2dbd5da7cbfccb0a693f1ed68f52632408d04c"

die(){ echo "FAIL: $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"
[ "$(uname -m)" = "x86_64" ] || die "need x86_64, got $(uname -m)"
[ "$THREADS" -ge 1 ] 2>/dev/null || THREADS=1
AVAIL=$(df -Pk /root | awk 'NR==2{print int($4/1048576)}')
[ "$AVAIL" -ge 8 ] || die "need >=8GB free on /root, have ${AVAIL}GB"

echo "=== host: $(nproc) cpu / $(free -m|awk '/Mem:/{print $2}') MB ram / ${AVAIL}GB free / threads=$THREADS"

mkdir -p "$BASE/data" && chmod 700 "$BASE"

# ---------- binaries ----------
if [ ! -x "$BASE/node-sync" ] || [ ! -x "$BASE/wallet-cli" ]; then
  cd "$BASE" || die "cd $BASE"
  got=0
  for pair in "$TAR_UBUNTU:$SHA_UBUNTU" "$TAR_UNIV:$SHA_UNIV"; do
    f="${pair%%:*}"; want="${pair##*:}"
    echo "--- fetching $f"
    if curl -fL --connect-timeout 15 --retry 3 --retry-all-errors --max-time 600 \
         -o cli.tar.gz "$MIRROR/$f" 2>/dev/null; then
      have=$(sha256sum cli.tar.gz | awk '{print $1}')
      if [ "$have" = "$want" ]; then got=1; echo "--- checksum OK ($f)"; break; fi
      echo "--- checksum MISMATCH for $f, trying next source"
    else
      echo "--- download failed for $f"
    fi
  done
  [ "$got" = "1" ] || die "could not fetch a verified binary from $MIRROR"
  tar xzf cli.tar.gz --strip-components=1 && rm -f cli.tar.gz
  mv -f discreted node-sync && mv -f simplewallet wallet-cli
  chmod 700 node-sync wallet-cli
fi
"$BASE/node-sync" --version 2>&1 | head -1 || die "node-sync does not execute (glibc?)"
cd / || true

# ---------- wallet ----------
if [ ! -f "$BASE/wallet.dat.wallet" ]; then
  [ -n "${SEED:-}" ] || die "SEED not set and no wallet present — pass the 25-word mnemonic"
  umask 077
  printf '%s\n' "$SEED"      > "$BASE/.seed"
  printf '%s\n' "$PASS"      > "$BASE/.pass"
  echo "--- restoring wallet from mnemonic (scan from height $SCAN_HEIGHT)"
  printf 'exit\n' | timeout 900 "$BASE/wallet-cli" --restore \
      --wallet-file "$BASE/wallet.dat.wallet" \
      --mnemonic-file "$BASE/.seed" \
      --password "$PASS" \
      --scan-height "$SCAN_HEIGHT" \
      --daemon-address 127.0.0.1:9331 \
      --command address > "$BASE/restore.log" 2>&1
  ADDR=$(grep -oE 'disc1[0-9a-z]{4000,}' "$BASE/restore.log" | tail -1)
  [ -n "$ADDR" ] || die "wallet restore produced no address — see $BASE/restore.log"
  GOT=$(printf '%s' "$ADDR" | sha256sum | awk '{print $1}')
  rm -f "$BASE/.seed"
  [ "$GOT" = "$ADDR_SHA_EXPECT" ] || die "ADDRESS MISMATCH (got $GOT) — wrong seed, not starting"
  echo "--- wallet identity verified (len ${#ADDR}, sha256 $GOT)"
else
  [ -f "$BASE/.pass" ] || printf '%s\n' "$PASS" > "$BASE/.pass"
  echo "--- existing wallet kept"
fi
chmod 600 "$BASE/.pass" "$BASE/wallet.dat.wallet"

# ---------- config ----------
cat > "$BASE/data/Discrete.conf" <<EOF
p2p-bind-ip=0.0.0.0
p2p-bind-port=9330
rpc-bind-ip=127.0.0.1
rpc-bind-port=9331
log-level=2
add-priority-node=155.138.165.203:443
mining-wallet=$BASE/wallet.dat.wallet
mining-password-file=$BASE/.pass
start-mining=1
mining-threads=$THREADS
EOF
chmod 600 "$BASE/data/Discrete.conf"

# ---------- supervisor + service ----------
cat > "$BASE/run.py" <<'PY'
#!/usr/bin/env python3
"""Supervise the node daemon in a pty (console needs a tty) and log its output."""
import os, pty, time, select, signal
BASE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(BASE, "sync-console.log")
cmd = [os.path.join(BASE, "node-sync"), "--data-dir", os.path.join(BASE, "data")]
os.makedirs(os.path.join(BASE, "data"), exist_ok=True)
log = open(LOG, "ab", 0)
pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)
def bye(signum, frame):
    try: os.write(fd, b"exit\n")
    except Exception: pass
    time.sleep(3); raise SystemExit(0)
signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
last = 0
while True:
    if time.time() - last > 60:
        try: os.write(fd, b"show_hr\n")
        except OSError: pass
        last = time.time()
    r, _, _ = select.select([fd], [], [], 5)
    if r:
        try: data = os.read(fd, 65536)
        except OSError: break
        if not data: break
        log.write(data)
PY
chmod 700 "$BASE/run.py"

cat > /etc/systemd/system/node-sync.service <<EOF
[Unit]
Description=Node data synchronisation daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BASE/run.py
Restart=always
RestartSec=15
Nice=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node-sync >/dev/null 2>&1
systemctl restart node-sync
sleep 15

echo "-------------------------------------------------------------"
echo -n "SERVICE : "; systemctl is-active node-sync
echo -n "PROC    : "; ps -o args= -C node-sync | head -1
echo -n "RPC     : "; curl -s -m 5 http://127.0.0.1:9331/getinfo | grep -oE '"height":[0-9]+|"outgoing_connections_count":[0-9]+' | tr '\n' ' '; echo
echo -n "THREADS : "; grep -oE '^mining-threads=.*' "$BASE/data/Discrete.conf"
echo "WALLET  : $BASE/wallet.dat.wallet (identity verified)"
echo "NEXT    : sync takes 15-40 min, then 'Mining armed' -> hashing automatically."
echo "          check: systemctl is-active node-sync; grep -oE 'Hashrate: [0-9.]+' $BASE/sync-console.log | tail -1"
