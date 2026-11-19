#!/usr/bin/env bash
# Plain OpenSSH with a pinned host key: no third-party action ever holds the key,
# and a spoofed host is refused instead of being trusted on first use.
set -euo pipefail

: "${SSH_HOST:?}" "${SSH_USER:?}" "${SSH_KEY:?}" "${SSH_ALIAS:?}"
: "${KNOWN_HOSTS:?known-hosts is empty: pin the host key in a secret first}"

install -m 700 -d ~/.ssh
key_file=~/.ssh/id_"$SSH_ALIAS"
printf '%s\n' "$SSH_KEY" >"$key_file"
chmod 600 "$key_file"
# Keyed by the alias (HostKeyAlias below), so the pin holds whether the host
# secret is an IP or a name.
printf '%s\n' "$KNOWN_HOSTS" | awk -v alias="$SSH_ALIAS" 'NF >= 3 && $1 !~ /^#/ { $1 = alias; print }' >>~/.ssh/known_hosts
cat >>~/.ssh/config <<CONFIG
Host $SSH_ALIAS
  HostName $SSH_HOST
  User $SSH_USER
  IdentityFile $key_file
  IdentitiesOnly yes
  HostKeyAlias $SSH_ALIAS
  StrictHostKeyChecking yes
  ConnectTimeout 15
CONFIG
