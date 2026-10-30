#!/usr/bin/env python3
"""Verify a bundled MCP server initializes away from the source checkout.

Run with the project's MCP venv Python and a built .app path. No WDA or device
is needed: initialization and tool discovery do not issue device commands.
"""
import asyncio
import os
from pathlib import Path
import sys
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def check(app: Path) -> None:
    server = app.resolve() / "Contents/Resources/mcp-server/imirror_mcp.py"
    with tempfile.TemporaryDirectory(prefix="imirror-bundle-check-") as cwd:
        parameters = StdioServerParameters(command=sys.executable, args=[str(server)], cwd=cwd,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                 "IMIRROR_TARGET": "simulator", "IMIRROR_WDA": "http://127.0.0.1:8201"})
        async with stdio_client(parameters) as (read, write):
            async with ClientSession(read, write) as session:
                initialized = await session.initialize()
                tools = await session.list_tools()
                names = {tool.name for tool in tools.tools}
                assert {"ios_status", "ios_source", "ios_screenshot", "ios_run_sequence"} <= names
                assert initialized.instructions and "inspect the screen" in initialized.instructions
                print(f"Bundled MCP initialized: {len(names)} tools, agent instructions present.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-mcp-bundle.py /path/to/iMirror.app")
    asyncio.run(asyncio.wait_for(check(Path(sys.argv[1])), timeout=20))
