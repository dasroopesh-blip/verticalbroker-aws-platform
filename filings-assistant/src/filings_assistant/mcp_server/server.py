"""MCP server exposing the Filings Assistant tools over stdio.

Any MCP client (Claude Desktop, an IDE, another agent) can connect and call
``ingest_filing``, ``hybrid_search``, ``answer_question``, etc. The server is a
thin adapter: it forwards MCP tool calls to the shared ``ToolRegistry`` so
behavior is identical to the in-process agent.

Run it with:  python -m filings_assistant.mcp_server.server
(Requires the optional ``mcp`` extra:  pip install -e ".[mcp]")
"""

from __future__ import annotations

import json

from filings_assistant.common.logging import get_logger
from filings_assistant.mcp_server.tools import TOOL_SCHEMAS, ToolRegistry

logger = get_logger("mcp.server")


def build_server():  # pragma: no cover - requires optional mcp dependency
    """Construct and return a configured MCP Server instance."""
    from mcp.server import Server
    from mcp.types import TextContent, Tool

    from filings_assistant.common.tenant import default_tenant

    server = Server("filings-assistant")
    # SECURITY: in a real deployment the tenant is resolved from the connecting
    # principal's auth. For the stdio server we bind it from configuration
    # (FA_DEFAULT_TENANT_ID) at startup — one server process serves one tenant.
    registry = ToolRegistry(tenant=default_tenant())

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return [
            Tool(name=name, description=spec["description"], inputSchema=spec["input_schema"])
            for name, spec in TOOL_SCHEMAS.items()
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[TextContent]:
        logger.info("MCP tool call", tool=name)
        result = registry.call(name, arguments or {})
        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    return server


def main() -> None:  # pragma: no cover - requires optional mcp dependency
    """Run the MCP server over stdio."""
    import asyncio

    from mcp.server.stdio import stdio_server

    async def _run() -> None:
        server = build_server()
        async with stdio_server() as (read, write):
            await server.run(read, write, server.create_initialization_options())

    asyncio.run(_run())


if __name__ == "__main__":
    main()
