#!/usr/bin/env bash
# Applies the four carried patches at build time. Each patch function is idempotent by
# marker and fails loudly when its anchor has moved, which is the point: a vendor bump
# that changes the adapter should stop the build, not surprise a running bot.
set -Eeuo pipefail
: "${HERMES_INSTALL_DIR:=/opt/hermes}"
hermes_install_dir() { printf '%s' "$HERMES_INSTALL_DIR"; }
log_warn() { printf 'warn  %s\n' "$*" >&2; }
# shellcheck source=/dev/null
source /tmp/patches/60-hermes.sh
for f in \
    "$(hermes_install_dir)/plugins/platforms/email/adapter.py:hermes_patch_email_folder_file" \
    "$(hermes_install_dir)/plugins/platforms/teams/adapter.py:hermes_patch_teams_links_file" \
    "$(hermes_install_dir)/gateway/slash_commands.py:hermes_patch_help_file" \
    "$(hermes_install_dir)/gateway/platforms/base.py:hermes_patch_clarify_choices_file"
do
    path=${f%%:*}; fn=${f##*:}
    [[ -f $path ]] || { echo "the vendor tree has no ${path} — the patch cannot be placed" >&2; exit 1; }
    rc=0; "$fn" "$path" || rc=$?
    case $rc in
        0) echo "patched: ${path}" ;;
        3) echo "already patched: ${path}" ;;
        *) echo "REFUSED: ${fn} could not patch ${path} — the vendor changed, review the patch" >&2; exit 1 ;;
    esac
done
