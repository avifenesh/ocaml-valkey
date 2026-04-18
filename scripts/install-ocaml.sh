#!/usr/bin/env bash
# Install OCaml 5.3 toolchain + Eio inside WSL Ubuntu.
# Idempotent: re-running is safe.
set -euo pipefail

LOG=/tmp/ocaml-install.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date -Is)] Starting OCaml 5 toolchain install"

echo "--- apt deps ---"
# SUDO_PASS env var expected; read via sudo -S (not logged in shell history)
: "${SUDO_PASS:?SUDO_PASS env var must be set}"
echo "$SUDO_PASS" | sudo -S -v
sudo -n apt-get update -y
sudo -n apt-get install -y \
  build-essential m4 unzip pkg-config \
  libssl-dev zlib1g-dev libgmp-dev \
  curl bubblewrap git rsync

echo "--- opam install (if missing) ---"
if ! command -v opam >/dev/null 2>&1; then
  curl -fsSL https://opam.ocaml.org/install.sh -o /tmp/opam-install.sh
  # opam install script reads stdin for install path; '' means accept default.
  # Avoid `yes` + `pipefail` SIGPIPE trap by piping a single empty line.
  printf '\n' | bash /tmp/opam-install.sh
fi
opam --version

echo "--- opam init ---"
if [ ! -d "$HOME/.opam" ]; then
  opam init --bare --disable-sandboxing --yes --shell-setup
fi

echo "--- opam switch create 5.3.0 ---"
if ! opam switch list --short 2>/dev/null | grep -q "^5\.3\.0$"; then
  opam switch create 5.3.0 --yes
fi
eval "$(opam env --switch=5.3.0)"

echo "--- core toolchain ---"
opam install -y dune utop merlin ocaml-lsp-server ocamlformat odoc

echo "--- eio ---"
opam install -y eio eio_main

echo "[$(date -Is)] DONE"
echo "ocaml: $(ocaml -version)"
echo "dune:  $(dune --version)"
