#!/usr/bin/env bash
# Default-deny outbound firewall. Allows only the hosts in allowed-domains.txt,
# GitHub's published ranges, DNS, and the Docker host network.
# Installed root-owned at /usr/local/sbin and run via sudo (postStartCommand).
# To disable, rebuild with build arg ENABLE_FIREWALL=0 (see devcontainer.json).
set -euo pipefail
IFS=$'\n\t'

if [[ "$(cat /etc/devcontainer/enable-firewall 2>/dev/null || echo 1)" == "0" ]]; then
  echo "[firewall] disabled at build time -> leaving network unrestricted"
  exit 0
fi

DOMAINS_FILE=/etc/devcontainer/allowed-domains.txt

# Preserve Docker's internal DNS NAT rules, then reset everything else
DOCKER_DNS_RULES="$(iptables-save -t nat | grep "127\.0\.0\.11" || true)"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
if [[ -n "$DOCKER_DNS_RULES" ]]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  while read -r rule; do iptables -t nat $rule; done <<<"$DOCKER_DNS_RULES"
fi

# DNS (to configured resolvers only), loopback
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  iptables -A INPUT  -p udp -s "$ns" --sport 53 -j ACCEPT
  iptables -A INPUT  -p tcp -s "$ns" --sport 53 -j ACCEPT
done
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub ranges (git/web/api). Fetched before the lockdown.
echo "[firewall] fetching GitHub IP ranges"
gh_meta="$(curl -fsS --max-time 15 https://api.github.com/meta)"
while read -r cidr; do
  [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || continue  # IPv4 only
  ipset add -exist allowed-domains "$cidr"
done < <(jq -r '(.web + .api + .git)[]' <<<"$gh_meta")

# Allowlisted domains -> IPs
while read -r domain; do
  [[ -z "$domain" || "$domain" == \#* ]] && continue
  ips="$(dig +short +time=3 +tries=2 A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  if [[ -z "$ips" ]]; then
    echo "[firewall] WARN: could not resolve $domain (skipped)"
    continue
  fi
  while read -r ip; do ipset add -exist allowed-domains "$ip"; done <<<"$ips"
done <"$DOMAINS_FILE"

# Docker host network (needed for VS Code port forwarding)
HOST_IP="$(ip route | awk '/default/{print $3; exit}')"
HOST_NET="${HOST_IP%.*}.0/24"
iptables -A INPUT  -s "$HOST_NET" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NET" -j ACCEPT

# Default deny, allow established + allowlisted
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
# Reject (not drop) everything else so blocked calls fail fast
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Self-test
if curl -s --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "[firewall] ERROR: example.com is reachable; rules are not working" >&2; exit 1
fi
if ! curl -s --max-time 10 https://api.github.com/zen >/dev/null 2>&1; then
  echo "[firewall] ERROR: api.github.com unreachable; allowlist is broken" >&2; exit 1
fi
echo "[firewall] active: example.com blocked, api.github.com reachable"
