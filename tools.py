"""Tool definitions for the RAG Agent.

Tools are decorated with @tool. Some are real API-backed implementations
(e.g. Russian corporate bond facts via Wikipedia REST API), others are
stubs waiting for a real provider.
"""

from __future__ import annotations

import random

import requests
from langchain_core.tools import tool


# Russian Wikipedia REST API — used to fetch random facts about
# the Russian bond market. Wikipedia requires a descriptive User-Agent.
_WIKIPEDIA_HEADERS = {
    "User-Agent": "nemo-bot-RAG/1.0 (educational RAG bot; +https://github.com/)",
    "Accept": "application/json",
}
_WIKIPEDIA_API = "https://ru.wikipedia.org/w/api.php"
_WIKIPEDIA_SUMMARY_API = "https://ru.wikipedia.org/api/rest_v1/page/summary"
_BONDS_CATEGORY = "Категория:Облигации"
_REQUEST_TIMEOUT = 10  # seconds


def _fetch_bond_fact_sync() -> str:
    """Synchronous helper: perform the two GET calls and format the result."""
    try:
        # 1) GET list of articles in the «Облигации» category.
        list_resp = requests.get(
            _WIKIPEDIA_API,
            params={
                "action": "query",
                "format": "json",
                "list": "categorymembers",
                "cmtitle": _BONDS_CATEGORY,
                "cmlimit": 50,
                "cmtype": "page",
            },
            headers=_WIKIPEDIA_HEADERS,
            timeout=_REQUEST_TIMEOUT,
        )
        list_resp.raise_for_status()
        members = (
            list_resp.json()
            .get("query", {})
            .get("categorymembers", [])
        )
        if not members:
            return (
                "⚠️ Не удалось получить список статей рубрики "
                f"«{_BONDS_CATEGORY}» — категория пуста."
            )

        # 2) Pick a random article.
        article = random.choice(members)
        title = article["title"]
        slug = title.replace(" ", "_")

        # 3) GET the article summary.
        summary_resp = requests.get(
            f"{_WIKIPEDIA_SUMMARY_API}/{requests.utils.quote(slug, safe='_()')}",
            headers=_WIKIPEDIA_HEADERS,
            timeout=_REQUEST_TIMEOUT,
        )
        summary_resp.raise_for_status()
        data = summary_resp.json()

        extract = (data.get("extract") or "").strip()
        page_url = (
            data.get("content_urls", {})
            .get("desktop", {})
            .get("page", "https://ru.wikipedia.org/")
        )

        if not extract:
            return (
                f"📊 Случайный факт: статья «{title}» пока не имеет "
                "краткого описания в Википедии.\n"
                f"Источник: {page_url}"
            )

        # 4) Format the final answer in Russian.
        return (
            "📊 Случайный факт об облигациях / облигационном рынке РФ\n\n"
            f"Тема: {title}\n"
            f"{extract}\n\n"
            f"Источник: {page_url}"
        )

    except requests.Timeout:
        return "⚠️ Не удалось получить факт: превышено время ожидания ответа."
    except requests.RequestException as exc:
        return f"⚠️ Не удалось получить факт: ошибка сети ({exc})."
    except (ValueError, KeyError) as exc:
        return f"⚠️ Не удалось разобрать ответ API ({exc})."


@tool(parse_docstring=True)
def get_russian_corporate_bond_fact() -> str:
    """Получить случайный факт о корпоративных облигациях российского рынка.

    Выполняет два GET-запроса к публичному REST API русской Википедии:
      1) Получает список статей в категории «Облигации».
      2) Случайно выбирает одну статью и запрашивает её краткое описание.

    Args:
        (no parameters)

    Returns:
        Текст на русском языке со случайным фактом, темой и ссылкой
        на источник. При ошибках сети/API возвращает понятное
        русскоязычное сообщение об ошибке.
    """
    return _fetch_bond_fact_sync()


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
    get_russian_corporate_bond_fact,
    get_weather_stub,
    search_web_stub,
]