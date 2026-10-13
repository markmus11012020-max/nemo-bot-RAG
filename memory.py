"""User memory: heuristic extraction of facts + storage via embeddings in Pinecone."""

from __future__ import annotations

import logging
import re
import uuid
from datetime import datetime, timezone
from typing import List, Optional

from langchain_core.documents import Document

logger = logging.getLogger(__name__)

# Explicit "remember this" triggers
REMEMBER_KEYWORDS = [
    "запомни",
    "запомнить",
    "не забудь",
    "запиши",
    "сохрани",
    "remember",
    "don't forget",
    "save this",
    "note that",
]

# Patterns that look like durable personal facts (RU + EN)
FACT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # Name
    (re.compile(r"(?:меня\s+зовут|мое\s+имя|моё\s+имя|я\s*[—\-]\s*)\s*([A-Za-zА-Яа-яЁё]{2,40})", re.I), "name"),
    (re.compile(r"(?:my\s+name\s+is|i\s+am\s+called|i'm\s+)\s*([A-Za-z]{2,40})", re.I), "name"),
    # Age
    (re.compile(r"(?:мне|мой\s+возраст)\s*(\d{1,3})\s*(?:лет|года|год)?", re.I), "age"),
    (re.compile(r"(?:i\s+am|i'm)\s*(\d{1,3})\s*(?:years?\s+old)?", re.I), "age"),
    # City / location
    (re.compile(r"(?:я\s+живу\s+в|живу\s+в|из\s+города|город\s*[—\-:]?\s*)\s*([A-Za-zА-Яа-яЁё\-\s]{2,40})", re.I), "city"),
    (re.compile(r"(?:i\s+live\s+in|based\s+in|from)\s+([A-Za-z\-\s]{2,40})", re.I), "city"),
    # Job / role
    (re.compile(r"(?:я\s+работаю|моя\s+профессия|я\s*[—\-]\s*)\s*([A-Za-zА-Яа-яЁё\s]{3,50})\s*(?:в|на|$)", re.I), "job"),
    (re.compile(r"(?:i\s+work\s+as|i'm\s+a|i\s+am\s+a)\s+([A-Za-z\s]{3,50})", re.I), "job"),
    # Preferences
    (re.compile(r"(?:я\s+люблю|мне\s+нравится|предпочитаю)\s+(.+?)(?:\.|$)", re.I), "preference"),
    (re.compile(r"(?:i\s+like|i\s+love|i\s+prefer)\s+(.+?)(?:\.|$)", re.I), "preference"),
    # Language
    (re.compile(r"(?:говорю\s+на|мой\s+язык|предпочитаю\s+язык)\s+([A-Za-zА-Яа-яЁё\s]{2,30})", re.I), "language"),
]


def should_remember(text: str) -> bool:
    """True if the message explicitly asks to remember something."""
    lower = text.lower()
    return any(kw in lower for kw in REMEMBER_KEYWORDS)


def extract_facts(text: str) -> List[tuple[str, str]]:
    """
    Extract (category, value) pairs from free text via heuristics.
    Returns list of durable facts worth storing.
    """
    facts: list[tuple[str, str]] = []
    seen: set[str] = set()

    for pattern, category in FACT_PATTERNS:
        for match in pattern.finditer(text):
            value = match.group(1).strip(" .,;:!?\n\t\"'")
            if len(value) < 2 or len(value) > 120:
                continue
            key = f"{category}:{value.lower()}"
            if key in seen:
                continue
            seen.add(key)
            facts.append((category, value))

    # Explicit "запомни: ..." — take the rest of the sentence as a free-form note
    if should_remember(text):
        cleaned = text
        for kw in REMEMBER_KEYWORDS:
            # Remove the keyword, keep the rest as a note
            cleaned = re.sub(re.escape(kw), "", cleaned, flags=re.I)
        cleaned = cleaned.strip(r" :,—\-")
        if len(cleaned) >= 5:
            key = f"note:{cleaned.lower()[:80]}"
            if key not in seen:
                facts.append(("note", cleaned[:500]))

    return facts


class UserMemory:
    """
    Per-user memory backed by the same Pinecone vector store.
    Facts are stored as Documents with metadata:
      type=user_memory, user_id=<telegram_id>, category=<name|city|...>
    """

    def __init__(self, vector_manager) -> None:
        self.vm = vector_manager

    def _user_filter(self, user_id: str) -> dict:
        return {"user_id": user_id, "type": "user_memory"}

    def add_facts(self, user_id: str, facts: List[tuple[str, str]]) -> int:
        """Embed and store facts. Returns number of facts saved."""
        if not facts:
            return 0

        docs: list[Document] = []
        now = datetime.now(timezone.utc).isoformat()
        for category, value in facts:
            content = f"[user_memory:{category}] {value}"
            docs.append(
                Document(
                    page_content=content,
                    metadata={
                        "type": "user_memory",
                        "user_id": str(user_id),
                        "category": category,
                        "source": f"user:{user_id}",
                        "created_at": now,
                        "id": str(uuid.uuid4()),
                    },
                )
            )
        self.vm.add_documents(docs)
        logger.info("Saved %d memory facts for user %s", len(docs), user_id)
        return len(docs)

    def add_raw(self, user_id: str, text: str, category: str = "note") -> int:
        """Store a free-form note for the user."""
        return self.add_facts(user_id, [(category, text)])

    def search(self, user_id: str, query: str, k: int = 5) -> List[Document]:
        """Retrieve relevant memory chunks for this user."""
        try:
            # Prefer metadata filter if Pinecone supports it via similarity_search
            docs = self.vm.vector_store.similarity_search(
                query,
                k=k * 3,  # over-fetch then filter
                filter={"user_id": str(user_id), "type": "user_memory"},
            )
            if docs:
                return docs[:k]
        except Exception as exc:  # noqa: BLE001
            logger.debug("Filtered memory search failed (%s), falling back", exc)

        # Fallback: search without filter, keep only this user's docs
        all_docs = self.vm.similarity_search(query, k=k * 5)
        return [
            d
            for d in all_docs
            if d.metadata.get("user_id") == str(user_id)
            and d.metadata.get("type") == "user_memory"
        ][:k]

    def process_message(self, user_id: str, text: str) -> List[tuple[str, str]]:
        """
        Heuristically extract facts from a message and store them.
        Returns the list of facts that were saved.
        """
        facts = extract_facts(text)
        if facts:
            self.add_facts(user_id, facts)
        return facts

    def format_context(self, user_id: str, query: str, k: int = 5) -> str:
        """Build a short memory context string for the LLM prompt."""
        docs = self.search(user_id, query, k=k)
        if not docs:
            return ""
        lines = ["Known facts about the user:"]
        for d in docs:
            cat = d.metadata.get("category", "note")
            # page_content is like "[user_memory:name] Ivan"
            text = d.page_content
            if "] " in text:
                text = text.split("] ", 1)[-1]
            lines.append(f"- ({cat}) {text}")
        return "\n".join(lines)
