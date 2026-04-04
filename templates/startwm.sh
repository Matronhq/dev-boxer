#!/bin/sh
# XRDP session launcher — deployed by dev-boxer

unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

if [ -r /etc/profile ]; then
    . /etc/profile
fi

export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE

exec startxfce4
