"""RAG Agent package — Telegram-ready smart assistant."""

from .rag_agent import RAGAgent
from .config import RAGAgentConfig, OpenAIConfig, PineconeConfig, TelegramConfig
from .memory import UserMemory

__all__ = [
    "RAGAgent",
    "RAGAgentConfig",
    "OpenAIConfig",
    "PineconeConfig",
    "TelegramConfig",
    "UserMemory",
]

__version__ = "0.2.0"
