#!/bin/bash
if [[ "$TAVILY_ENABLED" == "true" ]]; then
    npx -y tavily-mcp
else
    # Sleep indefinitely without using CPU to prevent the CLI from 
    # constantly trying to restart a "failed" service.
    # It will be "running" but have zero tools.
    sleep infinity
fi
