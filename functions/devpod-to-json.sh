#!/usr/bin/env bash

devpod_to_json() {
    # Initialize JSON structure
    echo "{"
    echo "  \"ssh_connections\": ["

    # Read the config file and process Host lines
    first=true
    while IFS= read -r line; do
        if [[ $line =~ ^Host\ ([^.]+)\.devpod$ ]]; then
            name="${BASH_REMATCH[1]}"
            if [ "$first" = true ]; then
                first=false
            else
                echo "    },"
            fi
            echo "    {"
            echo "      \"host\": \"$name.devpod\","
            echo "      \"projects\": [{ \"paths\": [\"/workspaces/$name\"] }]"
        fi
    done < "${HOME}/.ssh/config.d/devpod"

    # Close the last entry if there was at least one match
    if [ "$first" = false ]; then
        echo "    }"
    fi

    # Close JSON structure
    echo "  ]"
    echo "}"
}

# Only execute the function if the script is being run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    devpod_to_json
fi
