"""Tool definitions for the RAG Agent.

Tools are decorated with @tool and currently contain stubs.
They will be connected to real external APIs later.
"""

from __future__ import annotations

from typing import Any, Optional

from langchain_core.tools import tool


@tool(parse_docstring=True)
def api_request_stub(
    endpoint: str,
    method: str = "GET",
    params: Optional[dict[str, Any]] = None,
    body: Optional[dict[str, Any]] = None,
) -> str:
    """Make a request to an external API (stub).

    This is a placeholder. Real implementation will call configured external APIs.

    Args:
        endpoint: API endpoint path or full URL.
        method: HTTP method (GET, POST, PUT, DELETE, etc.).
        params: Optional query parameters.
        body: Optional JSON body for POST/PUT requests.

    Returns:
        JSON string with the (stub) response.
    """
    # TODO: replace with real HTTP client + auth when integrating external APIs
    return (
        f"[STUB] api_request_stub called\n"
        f"  method={method}\n"
        f"  endpoint={endpoint}\n"
        f"  params={params}\n"
        f"  body={body}\n"
        f"Real API integration will be added later."
    )


@tool(parse_docstring=True)
def get_weather_stub(city: str, units: str = "metric") -> str:
    """Get current weather for a city (stub).

    Args:
        city: City name (e.g. "Moscow", "London").
        units: Temperature units — "metric" or "imperial".

    Returns:
        Stub weather description.
    """
    return (
        f"[STUB] Weather for {city} ({units}): "
        f"sunny, 22°C. Real weather API will be connected later."
    )


@tool(parse_docstring=True)
def search_web_stub(query: str, max_results: int = 5) -> str:
    """Search the web for information (stub).

    Args:
        query: Search query.
        max_results: Maximum number of results to return.

    Returns:
        Stub search results.
    """
    return (
        f"[STUB] Web search for '{query}' (max_results={max_results}). "
        f"Real search provider will be connected later."
    )


# Collect all tools for convenient import
ALL_TOOLS = [
    api_request_stub,
    get_weather_stub,
    search_web_stub,
]