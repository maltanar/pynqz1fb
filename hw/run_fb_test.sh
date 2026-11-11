#!/bin/bash
# Run build_fb_test.tcl with a free-memory check and a watchdog that stops Vivado before the
# machine runs out of memory.
#
#   hw/run_fb_test.sh <pynq_dir> <lean|pynq> <out_dir> [bitstream 0|1]
#
# Environment: VIVADO_SETTINGS (default /data/Vivado/2024.2/settings64.sh),
#              MIN_START_MB (default 5000), MIN_RUN_MB (default 1000).
set -u
here=$(cd "$(dirname "$0")" && pwd)
settings=${VIVADO_SETTINGS:-/data/Vivado/2024.2/settings64.sh}
min_start=${MIN_START_MB:-5000}
min_run=${MIN_RUN_MB:-1000}

avail_mb() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }

if [ $# -lt 3 ]; then
    echo "usage: $0 <pynq_dir> <lean|pynq> <out_dir> [bitstream 0|1]" >&2
    exit 2
fi
if [ "$(avail_mb)" -lt "$min_start" ]; then
    echo "Only $(avail_mb) MB available, need $min_start MB to start; not running Vivado." >&2
    exit 3
fi

mkdir -p "$3"
pynq_dir=$(cd "$1" && pwd)
out_dir=$(cd "$3" && pwd)
set -- "$pynq_dir" "$2" "$out_dir" "${4:-0}"
cd "$out_dir"   # Vivado writes some files (e.g. NA/ps7_summary.html) to the working directory
set +u   # Xilinx's settings scripts reference unset variables
source "$settings"
set -u
vivado -mode batch -nojournal -log "$3/$2.log" -source "$here/build_fb_test.tcl" \
    -tclargs "$1" "$2" "$3" "${4:-0}" 1 > "$3/$2.stdout" 2>&1 &
vivado_pid=$!

while kill -0 $vivado_pid 2>/dev/null; do
    if [ "$(avail_mb)" -lt "$min_run" ]; then
        echo "Available memory dropped to $(avail_mb) MB; stopping Vivado." >&2
        pkill -TERM -P $vivado_pid; kill -TERM $vivado_pid
        pkill -TERM -f "$3/fb_$2/" 2>/dev/null
        sleep 5
        pkill -KILL -f "$3/fb_$2/" 2>/dev/null
        exit 4
    fi
    sleep 2
done
wait $vivado_pid
rc=$?
echo "Vivado exited with $rc; log: $3/$2.log"
exit $rc
