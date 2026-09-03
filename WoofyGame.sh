#!/bin/sh
printf '\033c\033]0;%s\a' Woofy Game
base_path="$(dirname "$(realpath "$0")")"
"$base_path/WoofyGame.x86_64" "$@"
