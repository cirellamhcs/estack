#!/bin/sh
# Egress router: hosts' default route points here. Forwards anything (any protocol,
# any port) to the internet, drops private/Tailscale/loopback destinations, never
# forwards between host networks, and answers DNS (refusing answers that point at
# private addresses, i.e. DNS rebinding).
set -eu
# Every host network carries "default via <router>", which Podman also installs in
# the router itself. Drop those self-pointing routes (now and whenever a network is
# connected later), so the only default route left is the egress network's.
drop_self_routes() {
  for a in $(ip -4 -o addr show | awk '{split($4,x,"/"); print x[1]}'); do
    while ip -4 route del default via "$a" 2>/dev/null; do :; done
  done
}
drop_self_routes
( while sleep 2; do drop_self_routes; done ) &
EGRESS_IF=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$EGRESS_IF" ] || { echo "no default route" >&2; exit 1; }
cat > /tmp/rules.nft <<NFT
flush ruleset

table inet omnigent {
  set private4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 }
  }

  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    iifname != "$EGRESS_IF" meta l4proto { tcp, udp } th dport 53 accept
    iifname != "$EGRESS_IF" icmp type echo-request accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname != "$EGRESS_IF" oifname "$EGRESS_IF" ip daddr != @private4 accept
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$EGRESS_IF" masquerade
  }
}
NFT
nft -f /tmp/rules.nft
UP=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
echo "router: egress via $EGRESS_IF, DNS upstream $UP"
exec dnsmasq --keep-in-foreground --no-resolv --server="$UP" --stop-dns-rebind --log-facility=- --no-hosts
