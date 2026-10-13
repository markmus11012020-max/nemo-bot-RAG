"""URL ingestion utilities: fetch page, clean text, chunk, embed, store."""

from __future__ import annotations

import logging
import re
from typing import List, Optional
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup
from langchain_core.documents import Document
from langchain_text_splitters import RecursiveCharacterTextSplitter

logger = logging.getLogger(__name__)

# Heuristic patterns that indicate the user wants a page to be read/ingested
URL_PATTERNS = [
    re.compile(r"https?://[^\s<>\"']+", re.IGNORECASE),
    re.compile(r"www\.[^\s<>\"']+", re.IGNORECASE),
]

INGEST_KEYWORDS = [
    "прочитай",
    "прочти",
    "читай",
    "прочитай страницу",
    "прочитай сайт",
    "прочитай ссылку",
    "загрузи",
    "загрузить",
    "добавь в базу",
    "индексируй",
    "проанализируй страницу",
    "read this",
    "read the page",
    "read url",
    "fetch",
    "ingest",
    "index this",
    "summarize this page",
    "analyze this url",
]


def extract_urls(text: str) -> List[str]:
    """Extract all HTTP(S) URLs from free text."""
    urls: list[str] = []
    for pattern in URL_PATTERNS:
        for match in pattern.findall(text):
            url = match.rstrip(".,);]")
            if not url.startswith("http"):
                url = "https://" + url
            if url not in urls:
                urls.append(url)
    return urls


def should_ingest_url(text: str) -> bool:
    """Heuristic: does the message request reading/indexing a page?"""
    lower = text.lower()
    has_url = bool(extract_urls(text))
    has_keyword = any(kw in lower for kw in INGEST_KEYWORDS)
    # If there is a URL and either an explicit keyword or the message is short
    # (likely "read this: <url>"), treat as ingest request.
    return has_url and (has_keyword or len(text.split()) < 25)


def fetch_page_text(url: str, timeout: int = 20) -> str:
    """Download a page and extract clean visible text."""
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (compatible; RAGAgent/1.0; +https://example.com/bot)"
        )
    }
    resp = requests.get(url, headers=headers, timeout=timeout)
    resp.raise_for_status()

    content_type = resp.headers.get("Content-Type", "").lower()
    if "html" in content_type or url.endswith((".html", ".htm", "/")):
        soup = BeautifulSoup(resp.content, "lxml")
        for tag in soup(["script", "style", "noscript", "header", "footer", "nav"]):
            tag.decompose()
        text = soup.get_text(separator="\n", strip=True)
        # Collapse excessive blank lines
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text

    # Fallback for plain text / markdown
    return resp.text


def url_to_documents(
    url: str,
    chunk_size: int = 1000,
    chunk_overlap: int = 200,
) -> List[Document]:
    """Fetch URL, split into chunks, return LangChain Documents."""
    logger.info("Fetching URL: %s", url)
    raw_text = fetch_page_text(url)
    if not raw_text.strip():
        logger.warning("Empty content for URL: %s", url)
        return []

    doc = Document(
        page_content=raw_text,
        metadata={
            "source": url,
            "type": "url_ingest",
            "title": _guess_title(raw_text, url),
        },
    )

    splitter = RecursiveCharacterTextSplitter(
        chunk_size=chunk_size,
        chunk_overlap=chunk_overlap,
    )
    chunks = splitter.split_documents([doc])
    # Ensure every chunk keeps the source URL
    for i, chunk in enumerate(chunks):
        chunk.metadata["source"] = url
        chunk.metadata["chunk_index"] = i
    logger.info("Split %s into %d chunks", url, len(chunks))
    return chunks


def _guess_title(text: str, url: str) -> str:
    """Very simple title extraction from first non-empty line or domain."""
    for line in text.splitlines():
        line = line.strip()
        if 10 < len(line) < 120:
            return line
    parsed = urlparse(url)
    return parsed.netloc or url