"""Configuration for the RAG Agent.

All sensitive values are loaded from environment variables / .env file.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class OpenAIConfig:
    """Settings for OpenAI-compatible chat & embeddings endpoints."""

    api_key: str = field(default_factory=lambda: os.getenv("OPENAI_API_KEY", ""))
    base_url: str = field(
        default_factory=lambda: os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    )
    model: str = field(default_factory=lambda: os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    embedding_model: str = field(
        default_factory=lambda: os.getenv(
            "OPENAI_EMBEDDING_MODEL", "text-embedding-3-small"
        )
    )


@dataclass(frozen=True)
class PineconeConfig:
    """Settings for Pinecone vector database."""

    api_key: str = field(default_factory=lambda: os.getenv("PINECONE_API_KEY", ""))
    index_name: str = field(
        default_factory=lambda: os.getenv("PINECONE_INDEX_NAME", "rag-agent-index")
    )
    namespace: str = field(
        default_factory=lambda: os.getenv("PINECONE_NAMESPACE", "default")
    )
    dimension: int = field(
        default_factory=lambda: int(os.getenv("PINECONE_DIMENSION", "1536"))
    )
    cloud: str = field(default_factory=lambda: os.getenv("PINECONE_CLOUD", "aws"))
    region: str = field(
        default_factory=lambda: os.getenv("PINECONE_REGION", "us-east-1")
    )


@dataclass
class RAGAgentConfig:
    """Aggregate configuration for the RAG agent."""

    openai: OpenAIConfig = field(default_factory=OpenAIConfig)
    pinecone: PineconeConfig = field(default_factory=PineconeConfig)
    chunk_size: int = 1000
    chunk_overlap: int = 200
    retrieval_k: int = 4
    system_prompt: str = (
        "You are a helpful RAG assistant. "
        "Use the vector knowledge base to answer questions accurately. "
        "When a URL is provided, ingest its content first, then answer. "
        "Use available tools when external API data is required. "
        "Always ground answers in retrieved context when possible."
    )

    def validate(self) -> None:
        """Raise ValueError if critical credentials are missing."""
        if not self.openai.api_key:
            raise ValueError("OPENAI_API_KEY is not set")
        if not self.pinecone.api_key:
            raise ValueError("PINECONE_API_KEY is not set")