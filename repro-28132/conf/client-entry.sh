#!/bin/sh
# Move our own PID out of the cgroup-v2 root so Nomad can enable controllers
# at root subtree_control (the "no internal processes" rule). Without this the
# client fails to start inside a container with: "failed to create nomad
# cgroup: write /sys/fs/cgroup/cgroup.subtree_control: device or resource busy".
mkdir -p /sys/fs/cgroup/init
echo $$ > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
for c in $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null); do
  echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
done
exec /nomad agent -config=/etc/nomad/client.hcl
