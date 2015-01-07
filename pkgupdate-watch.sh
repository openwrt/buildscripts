#!/bin/bash

. ./shared/functions.sh

sdkdir="$(readlink -f $CACHE_DIR/sdk/)/"

while true; do
	out="$(
		date
		grep -slE "^Uid:\s+$(id -u)\s" /proc/[0-9]*/status | while read pid; do
			pid="${pid#/proc/}"
			pid="${pid%/status}"

			cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
			case "$cwd" in $sdkdir*)
				cmd="$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | head -n 1)"
				#case "$cmd" in "make -C "*)
					cwd="${cwd%%/build_dir/*}"
					echo "[${cwd:${#sdkdir}}] ${cmd:0:72}"
				#;; esac
			;; esac
		done | sort
	)"

	clear
	echo "$out"
	sleep 2
done
