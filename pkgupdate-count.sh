#!/usr/bin/env bash

[ -f shared/functions.sh ] || {
	echo "Please execute as ./${0##*/}" >&2
	exit 1
}

watch -n 5 '
	. ./shared/functions.sh

	for target in $(fetch_remote_targets); do
		echo -n "$target: "
		find "$CACHE_DIR/repo-local/$target" -name "*.ipk" 2>/dev/null | wc -l
	done
'
