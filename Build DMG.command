#!/bin/bash
# Double-click me in Finder to build dist/Isle.dmg.
cd "$(dirname "$0")"
./Packaging/make-dmg.sh
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Done. Upload dist/Isle.dmg to a new GitHub Release."
else
  echo "Build failed (exit $status). Copy the messages above and send them to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window…"
