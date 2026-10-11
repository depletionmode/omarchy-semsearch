#!/bin/bash
# Stop and remove the semsearchd service. With --purge, also delete the index,
# the downloaded model and runtime, and the page cache.
set -euo pipefail

unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/semsearch.service"
systemctl --user disable --now semsearch.service 2>/dev/null || true
rm -f "$unit"
systemctl --user daemon-reload

if [[ ${1:-} == --purge ]]; then
  rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/semsearch" "${XDG_CACHE_HOME:-$HOME/.cache}/semsearch"
fi
