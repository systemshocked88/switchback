#!/bin/sh
# Same as: sh install.sh uninstall [--dry-run]
exec sh "$(cd "$(dirname "$0")" && pwd)/install.sh" uninstall "$@"
