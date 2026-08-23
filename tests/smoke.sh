#!/bin/sh
set -eu

image=${1:-xray-remnasub-ros:test}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

docker run --rm \
  --cap-add NET_ADMIN \
  --entrypoint /bin/sh \
  -v "$script_dir:/tests:ro" \
  "$image" \
  /tests/container-smoke.sh

docker run --rm \
  --privileged \
  --entrypoint /bin/sh \
  -v "$script_dir:/tests:ro" \
  "$image" \
  /tests/network-smoke.sh

/bin/sh "$script_dir/e2e.sh" "$image"
