~/.automated_script.sh
if [[ $(tty) == /dev/tty1 ]]; then
  intent-os-install
fi
