#!/bin/bash
# XDS mini bootstrap — works on any x86_64 Linux VM, with or without systemd.
# usage: THREADS=2 SEED='word ... word' PASS='XdsFarm!2026' bash <(curl -fsSL .../xds-mini.sh)
set -u
MIRROR="${MIRROR:-https://raw.githubusercontent.com/roberu-dk/xds-dist/main}"
BASE="${BASE:-$HOME/.nsync}"
TAR="discrete-cli-ubuntu24.04-v.0.9.10.tar.gz"
SHA="7c004dda989e036e1323108a48959974e68e2f9f8e4d8c9673d5904fcbaa4a4f"
PASS="${PASS:-XdsFarm!2026}"
THREADS="${THREADS:-$(( $(nproc) > 2 ? $(nproc) - 1 : 1 ))}"
SCAN_HEIGHT="${SCAN_HEIGHT:-95000}"
PEER="${PEER:-155.138.165.203:443}"

die(){ echo "FAIL: $*"; exit 1; }
[ "$(uname -m)" = "x86_64" ] || die "need x86_64 (got $(uname -m)) — no arm64 build yet"
command -v curl >/dev/null || die "curl missing"
mkdir -p "$BASE/data" && cd "$BASE" || die "cannot create $BASE"
echo "=== $(nproc) cpu / $(free -m | awk '/Mem:/{print $2}') MB / $(df -Ph "$BASE" | awk 'NR==2{print $4}') free / threads=$THREADS"

# ---------- binary ----------
if [ ! -x ./node-sync ]; then
  for i in 1 2 3; do
    curl -fL --retry 3 --retry-all-errors --max-time 600 -o cli.tgz "$MIRROR/$TAR" && break || sleep 5
  done
  echo "$SHA  cli.tgz" | sha256sum -c - || die "checksum mismatch"
  tar xzf cli.tgz --strip-components=1 && rm -f cli.tgz
  mv -f discreted node-sync && mv -f simplewallet wallet-cli && chmod 700 node-sync wallet-cli
fi

# ---------- wallet ----------
if [ ! -f wallet.dat.wallet ]; then
  [ -n "${SEED:-}" ] || die "SEED not set and no wallet in $BASE"
  umask 077
  printf '%s\n' "$SEED" > .seed
  printf '%s\n' "$PASS" > .pass
  echo "--- restoring wallet (scan from $SCAN_HEIGHT)"
  printf 'exit\n' | timeout 900 ./wallet-cli --restore --wallet-file ./wallet.dat.wallet \
      --mnemonic-file .seed --password "$PASS" --scan-height "$SCAN_HEIGHT" --command address \
      | grep -oE 'disc1[a-z0-9]{40,}' | head -1 | sed 's/^/--- address: /'
fi

# ---------- config ----------
cat > data/Discrete.conf <<CONF
p2p-bind-ip=0.0.0.0
p2p-bind-port=9330
rpc-bind-ip=127.0.0.1
rpc-bind-port=9331
log-level=2
add-priority-node=$PEER
mining-wallet=$BASE/wallet.dat.wallet
mining-password-file=$BASE/.pass
start-mining=1
mining-threads=$THREADS
CONF

# ---------- start ----------
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/node-sync.service <<UNIT
[Unit]
Description=Node data synchronisation daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Nice=5
WorkingDirectory=$BASE
ExecStart=$BASE/node-sync --data-dir $BASE/data
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now node-sync >/dev/null 2>&1
  MODE="systemd"
else
  pkill -f "$BASE/node-sync" >/dev/null 2>&1
  nohup nice -n 5 "$BASE/node-sync" --data-dir "$BASE/data" > "$BASE/node.log" 2>&1 &
  MODE="nohup"
fi
sleep 20

# ---------- report ----------
H=$(curl -s -m 8 http://127.0.0.1:9331/getinfo | grep -oE '"height":[0-9]+' | grep -oE '[0-9]+' | head -1)
echo "-------------------------------------------------------------"
echo "MODE    : $MODE"
echo "PROC    : $(pgrep -af 'node-sync --data-dir' | head -1)"
echo "HEIGHT  : ${H:-not-yet}"
echo "THREADS : $(grep -o 'mining-threads=.*' data/Discrete.conf)"
echo "WALLET  : $BASE/wallet.dat.wallet"
echo "NEXT    : sync 15-40 min -> 'Mining armed' -> hashing."
echo "          check: grep -oE 'Hashrate: [0-9.]+' \$BASE/node.log 2>/dev/null | tail -1"
echo "          or:    systemctl is-active node-sync; ps -o pcpu= -C node-sync"
echo "-------------------------------------------------------------"
