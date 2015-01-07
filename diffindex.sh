#!/bin/bash

. ./bin/functions.sh

for target in $(fetch_remote_targets); do
	for feed in $(fetch_remote_feeds "$target"); do
		R="$CACHE_DIR/mirror/$target/packages/$feed"
		L="$CACHE_DIR/repo-local/$target/packages/$feed"

		if [ -s "$L/Packages" -a -s "$R/Packages.gz" ]; then
			echo -en "\nTarget $target Feed $feed\n\n"
			zcat "$R/Packages.gz" > "$R/Packages"
			diff -u "$R/Packages" "$L/Packages"
			rm "$R/Packages"
		fi
	done
done | less
