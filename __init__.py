"""RAG Agent package — ready for future Telegram bot integration."""

from .rag_agent import RAGAgent
from .config import RAGAgentConfig, OpenAIConfig, PineconeConfig

__all__ = [
    "RAGAgent",
    "RAGAgentConfig",
    "OpenAIConfig",
    "PineconeConfig",
]

__version__ = "0.1.0"