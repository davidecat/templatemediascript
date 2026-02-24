#!/bin/bash
cd /home/oooomedia/liq_scripts || exit 1
exec /usr/bin/liquidsoap --force-start script.liq -- user1=true
