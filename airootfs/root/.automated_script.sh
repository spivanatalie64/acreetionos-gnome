#!/usr/bin/env bash
# automated_script.sh — archiso script= boot param support
script_cmdline() {
    local param
    for param in $(</proc/cmdline); do
        case "${param}" in
            script=*) echo "${param#*=}"; return 0 ;;
        esac
    done
}
automated_script() {
    local script rt
    script="$(script_cmdline)"
    if [[ -n "${script}" && ! -x /tmp/startup_script ]]; then
        if [[ "${script}" =~ ^((http|https|ftp|tftp)://) ]]; then
            systemd-run --pty --quiet -p Wants=network-online.target -p After=network-online.target \
                curl "${script}" --location --retry-connrefused --retry 10 --fail -s -o /tmp/startup_script
            rt=$?
        else
            cp "${script}" /tmp/startup_script
            rt=$?
        fi
        if [[ ${rt} -eq 0 ]]; then
            chmod +x /tmp/startup_script
            /tmp/startup_script
        fi
    fi
}
if [[ $(tty) == "/dev/tty1" ]]; then
    automated_script
fi
