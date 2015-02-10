#!/usr/bin/env bash

. ./shared/functions.sh

trap 'clear; exit 0' SIGINT SIGTERM

clear

while true; do
	echo -en "\033[0;0f"
	fetch_remote_targets | while read target; do (
		cd "$CACHE_DIR/sdk/$target"
		log="$(find logs/ -type f -name compile.txt -printf '%C@ %h\n' 2>/dev/null | \
			sort -nr | sed -ne '1s/^[0-9.]\+ //p')"

		if [ -d "$log" ]; then
			d1=$(date +%s)
			d2=$(date +%s -r "$log/compile.txt")

			if [ $(($d1 - $d2)) -gt 5 ]; then
				log="- idle -"
				msg=""
			else
				msg="$(tail -n1 "$log/compile.txt")"
				if [ ${#msg} -gt 80 ]; then
					msg="${msg:0:80}"
				fi
			fi
		else
			log="- pending -"
			msg=""
		fi

		printf "\033[K%-20s %-16s %s\n" "[$target]" "[${log##*/}]" "$msg"
	); done
	sleep 1
done
