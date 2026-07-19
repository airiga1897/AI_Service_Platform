#!/bin/sh
set -eu

mode="${1:-client}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$mode" in
  server)
    binary="vpnserver"
    ;;
  client)
    binary="vpnclient"
    ;;
  exec)
    exec "$@"
    ;;
  *)
    exec "$mode" "$@"
    ;;
esac

data_dir="${SOFTETHER_DATA_DIR:-/mnt}"
mkdir -p "$data_dir"

for artifact in vpnserver vpnclient vpncmd hamcore.se2; do
  ln -sf "/usr/local/bin/$artifact" "$data_dir/$artifact"
done

cd "$data_dir"
exec "./$binary" execsvc
