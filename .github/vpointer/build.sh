#!/bin/sh
# builds CI's test mouse (needs gcc and wayland-devel)
set -e
cd "$(dirname "$0")"
wayland-scanner client-header virtual-pointer.xml vp.h
wayland-scanner private-code virtual-pointer.xml vp.c
gcc -O2 -o "${1:-/usr/local/bin/vpointer}" vpointer.c vp.c $(pkg-config --cflags --libs wayland-client)
