#!/bin/bash
# Human-readable source for the base64 blob embedded in
# shellprocess-audio-fix.conf. This file is NOT executed by Calamares and
# is NOT installed onto the target system - it exists purely so the actual
# fix is reviewable/maintainable without decoding base64 by hand.
#
# WHY BASE64: see shellprocess-bootfix.source.sh in this directory for the
# full explanation of Calamares' variable-expansion pass (KWordMacroExpander
# in CommandList::run()). Same issue applies here since this script uses
# bare $ shell variables.
#
# To regenerate the blob after editing this file:
#   base64 -w0 shellprocess-audio-fix.source.sh
# then paste the output into shellprocess-audio-fix.conf as:
#   command: "-echo <blob> | base64 -d | bash"
#
# WHY THIS EXISTS: users report audible static/crackling on the installed
# system. The base image ships a PipeWire quantum (frame buffer) override
# that forces a value too high for some hardware, causing audible
# artifacts. Rather than guess a hardware-specific replacement number,
# drop in a conf.d snippet that resets the quantum settings back to
# PipeWire's own stock upstream defaults (quantum=1024, min-quantum=32,
# max-quantum=2048). conf.d snippets are merged in sorted filename order
# and later files win for duplicate keys, so naming this "99-" ensures it
# is applied last and overrides whatever set it too high, without needing
# to know exactly which file did so.
{
    if command -v pipewire &>/dev/null || pacman -Qq pipewire &>/dev/null; then
        mkdir -p /etc/pipewire/pipewire.conf.d
        cat > /etc/pipewire/pipewire.conf.d/99-quantum-fix.conf <<'EOF'
context.properties = {
    default.clock.rate        = 48000
    default.clock.quantum     = 1024
    default.clock.min-quantum = 32
    default.clock.max-quantum = 2048
}
EOF
    fi
} > /var/log/calamares-audio-fix.log 2>&1
exit 0
