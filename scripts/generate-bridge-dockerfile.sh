#!/usr/bin/env bash
# Insert the store's bridge status patch only into the Docker builder stage.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 SOURCE_DOCKERFILE OUTPUT_DOCKERFILE" >&2
  exit 2
fi

awk '
  /^[[:space:]]*FROM[[:space:]]/ {
    in_builder = ($0 ~ /[[:space:]]AS[[:space:]]+builder[[:space:]]*$/)
    if (in_builder) builders++
  }
  {
    print
    if (in_builder && $0 ~ /^[[:space:]]*COPY[[:space:]]+\.[[:space:]]+\.[[:space:]]*$/) {
      copies++
      print "COPY --from=kaspa-dashboard-patch /node-status.patch /tmp/kaspa-node-status.patch"
      print "RUN apk add --no-cache patch && patch --batch --fuzz=0 -p1 < /tmp/kaspa-node-status.patch"
    }
    if (in_builder && copies == 1 && $0 ~ /cargo build -p kaspa-stratum-bridge/) builds++
  }
  END {
    if (builders != 1 || copies != 1 || builds != 1) {
      print "Unsupported upstream bridge Dockerfile: expected one builder stage, source COPY and bridge build" > "/dev/stderr"
      exit 1
    }
  }
' "$1" > "$2"
