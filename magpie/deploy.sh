#!/usr/bin/env bash
# Magpie hub pipeline (run as ubuntu on the Frankfurt server).
#
#   deploy.sh                build, test, install and restart onto this commit
#   deploy.sh --build-only   build into ./build and run the tests
#   deploy.sh --stage        build, test and install into /opt/magpie/releases
#                            only (what /usr/local/sbin/magpie-deploy runs)
#
# The hub is only restarted onto a build that passed the engine tests against
# a real hub; if the restarted hub isn't healthy within a minute, the last
# good release comes back.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=$HOME/.local/go/bin:$PATH
OPT=/opt/magpie
SHA=$(git rev-parse --short=12 HEAD)

echo "== build $SHA"
go run build.go -no-upgrade build syncthing
mkdir -p build
mv syncthing build/syncthing
go build -o build/magpie-hubd ./cmd/magpie-hubd
build/syncthing --version

echo "== test"
go vet ./lib/magpie ./cmd/magpie-hubd
MAGPIE_SYNCTHING=$PWD/build/syncthing go test -count=1 ./lib/magpie ./cmd/magpie-hubd

[[ "${1:-}" == --build-only ]] && exit 0

echo "== install $SHA"
REL=$OPT/releases/$SHA
mkdir -p "$REL"
install -m 0755 build/syncthing build/magpie-hubd "$REL/"
[[ "${1:-}" == --stage ]] && exit 0

PREV=$(readlink "$OPT/current" || true)
ln -sfn "releases/$SHA" "$OPT/current.new" && mv -T "$OPT/current.new" "$OPT/current"
sudo -n systemctl restart magpie-hub
sudo -n systemctl restart magpie-hubd

healthy() {
  for _ in $(seq 30); do
    if sudo -n -u magpie "$OPT/current/magpie-hubd" status --home /var/lib/magpie >/dev/null 2>&1 \
       && ss -Htln | grep -q ':22000 ' && sudo -n /usr/local/sbin/magpie-firewall check >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}
if healthy; then
  ln -sfn "releases/$SHA" "$OPT/last-good.new" && mv -T "$OPT/last-good.new" "$OPT/last-good"
  echo "== deployed $SHA"
  # keep the five newest releases
  ls -1t "$OPT/releases" | tail -n +6 | while read -r old; do
    [[ "$OPT/releases/$old" == "$(readlink -f "$OPT/last-good")" ]] || rm -rf "${OPT:?}/releases/$old"
  done
else
  echo "== $SHA is not healthy; rolling back to $PREV"
  ln -sfn "${PREV:-$(readlink "$OPT/last-good")}" "$OPT/current.new" && mv -T "$OPT/current.new" "$OPT/current"
  sudo -n systemctl restart magpie-hub
  sudo -n systemctl restart magpie-hubd
  exit 1
fi
