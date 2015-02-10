#!/usr/bin/env bash

watch -n 5 '
	. ./shared/functions.sh

	for target in $(fetch_remote_targets); do
		echo -n "$target: "
		find "$CACHE_DIR/repo-local/$target" -name "*.ipk" 2>/dev/null | wc -l
	done
'
