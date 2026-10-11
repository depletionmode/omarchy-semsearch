#!/bin/bash
# Set up the search daemon: download llama.cpp and the EmbeddingGemma 2 model
# (about 900 MB, each file checked against a pinned SHA-256), then install and
# start semsearchd as a systemd user service. Needs no root and can be re-run.
set -euo pipefail

# The first llama.cpp builds that know EmbeddingGemma 2 are b11457 and later.
LLAMA_BUILD=b11556
LLAMA_SHA256=68c61a837d6f8268b4b3117becc02e892c80f5ae9cfd1d54bc99261fe1380ae2
MODEL_REPO=https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8
MODELS=(
  "embeddinggemma-2-Q8_0.gguf 2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
  "mmproj-embeddinggemma-2-Q8_0.gguf c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"
)

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

[[ $(uname -m) == x86_64 ]] || fail "only x86-64 is supported (the llama.cpp build is x64)"
for tool in uv curl sha256sum tar git pdftotext pdftoppm systemctl; do
  command -v "$tool" >/dev/null || fail "missing dependency: $tool (try: sudo pacman -S --needed uv poppler)"
done

here=$(dirname "$(readlink -f "$0")")
data="${XDG_DATA_HOME:-$HOME/.local/share}/semsearch"
mkdir -p "$data/llama" "$data/models"

# Download to a temporary name and only keep the file once its hash matches.
fetch() {
  local url=$1 dest=$2 sha=$3
  curl -fL --retry 3 -o "$dest.part" "$url"
  echo "$sha  $dest.part" | sha256sum --check --quiet || fail "checksum mismatch for $url"
  mv "$dest.part" "$dest"
}

if [[ ! -x $data/llama/llama-server ]]; then
  archive="$data/llama-$LLAMA_BUILD.tar.gz"
  fetch "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-ubuntu-vulkan-x64.tar.gz" \
    "$archive" "$LLAMA_SHA256"
  tar -xzf "$archive" -C "$data/llama" --strip-components=1
  rm "$archive"
fi

for model in "${MODELS[@]}"; do
  read -r file sha <<<"$model"
  [[ -f $data/models/$file ]] || fetch "$MODEL_REPO/$file" "$data/models/$file" "$sha"
done

unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/semsearch.service"
mkdir -p "$(dirname "$unit")"
cat >"$unit" <<UNIT
[Unit]
Description=Semantic search daemon for the Omarchy shell

[Service]
ExecStart=$here/semsearchd
Restart=on-failure
Nice=10

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable semsearch.service
systemctl --user restart semsearch.service
echo "semsearchd is running. The first index is being built in the background."
