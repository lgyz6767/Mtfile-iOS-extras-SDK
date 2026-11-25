#!/bin/sh
cd "$(dirname "$0")"
rm -f LuaDemo.mtextra
zip -qr LuaDemo.mtextra manifest.json main.lua
echo "built $(pwd)/LuaDemo.mtextra"
