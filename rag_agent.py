"""
RAG Agent — OOP implementation based on LangChain Deep Agents + Pinecone.

Capabilities:
  1. Vector store (Pinecone) for semantic search / RAG.
  2. Tool-calling stubs ready for future external API integration.
  3. Heuristic URL detection → fetch → chunk → embed → store → answer.

Designed to be later plugged into a Telegram bot.
"""

from __future__ import annotations

import logging
import sys
from typing import List, Optional

from langchain_core.documents import Document
from langchain_core.messages import HumanMessage
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain_pinecone import PineconeVectorStore
from pinecone import Pinecone, ServerlessSpec

from config import RAGAgentConfig
from tools import ALL_TOOLS
from url_ingestor import (
    extract_urls,
    should_ingest_url,
    url_to_documents,
)

logger = logging.getLogger(__name__)


class VectorStoreManager:
    """Manages connection to Pinecone and document indexing."""

    def __init__(self, config: RAGAgentConfig) -> None:
        self.config = config
        self._pc: Optional[Pinecone] = None
        self._index = None
        self._vector_store: Optional[PineconeVectorStore] = None
        self._embeddings: Optional[OpenAIEmbeddings] = None

    @property
    def embeddings(self) -> OpenAIEmbeddings:
        if self._embeddings is None:
            self._embeddings = OpenAIEmbeddings(
                model=self.config.openai.embedding_model,
                api_key=self.config.openai.api_key,
                base_url=self.config.openai.base_url,
            )
        return self._embeddings

    def connect(self) -> PineconeVectorStore:
        """Initialize Pinecone client, ensure index exists, return VectorStore."""
        if self._vector_store is not None:
            return self._vector_store

        cfg = self.config.pinecone
        self._pc = Pinecone(api_key=cfg.api_key)

        existing = [idx["name"] for idx in self._pc.list_indexes()]
        if cfg.index_name not in existing:
            logger.info("Creating Pinecone index '%s' ...", cfg.index_name)
            self._pc.create_index(
                name=cfg.index_name,
                dimension=cfg.dimension,
                metric="cosine",
                spec=ServerlessSpec(cloud=cfg.cloud, region=cfg.region),
            )

        self._index = self._pc.Index(cfg.index_name)
        self._vector_store = PineconeVectorStore(
            index=self._index,
            embedding=self.embeddings,
            namespace=cfg.namespace,
        )
        logger.info(
            "Connected to Pinecone index '%s' (namespace=%s)",
            cfg.index_name,
            cfg.namespace,
        )
        return self._vector_store

    @property
    def vector_store(self) -> PineconeVectorStore:
        if self._vector_store is None:
            return self.connect()
        return self._vector_store

    def add_documents(self, documents: List[Document]) -> List[str]:
        """Embed and upsert documents. Returns list of IDs."""
        if not documents:
            return []
        ids = self.vector_store.add_documents(documents)
        logger.info("Indexed %d documents into Pinecone", len(documents))
        return ids

    def similarity_search(self, query: str, k: Optional[int] = None) -> List[Document]:
        """Retrieve top-k similar documents."""
        k = k or self.config.retrieval_k
        return self.vector_store.similarity_search(query, k=k)

    def test_connection(self) -> bool:
        """Lightweight connectivity check (list indexes + dummy embed)."""
        try:
            self.connect()
            # Force an embedding call to verify OpenAI-compatible endpoint
            _ = self.embeddings.embed_query("connection test")
            return True
        except Exception as exc:  # noqa: BLE001
            logger.error("Connection test failed: %s", exc)
            return False


class RAGAgent:
    """
    High-level RAG agent that combines:
      - Pinecone vector retrieval
      - Deep-agent style tool calling (stubs for now)
      - Automatic URL ingestion when the user provides a link

    The class is intentionally independent of any messenger (Telegram etc.).
    Call `agent.ask(user_message)` from your bot handler later.
    """

    def __init__(self, config: Optional[RAGAgentConfig] = None) -> None:
        self.config = config or RAGAgentConfig()
        self.config.validate()

        self.vector_manager = VectorStoreManager(self.config)
        self.vector_manager.connect()

        self._llm: Optional[ChatOpenAI] = None
        self._agent = None  # deep agent instance (lazy)
        self._tools = list(ALL_TOOLS)
        self._register_retrieval_tool()

    # ------------------------------------------------------------------
    # LLM & Deep Agent
    # ------------------------------------------------------------------

    @property
    def llm(self) -> ChatOpenAI:
        if self._llm is None:
            # Explicit ChatOpenAI so we can pass external base_url
            self._llm = ChatOpenAI(
                model=self.config.openai.model,
                api_key=self.config.openai.api_key,
                base_url=self.config.openai.base_url,
                temperature=0.2,
            )
        return self._llm

    def _register_retrieval_tool(self) -> None:
        """Create a retrieval tool bound to this instance's vector store."""

        vector_manager = self.vector_manager
        k = self.config.retrieval_k

        @tool(parse_docstring=True)
        def search_knowledge_base(query: str) -> str:
            """Search the internal vector knowledge base (Pinecone) for relevant information.

            Use this tool whenever the answer may be present in previously ingested
            documents or web pages.

            Args:
                query: Natural language search query.

            Returns:
                Concatenated relevant document chunks with sources.
            """
            docs = vector_manager.similarity_search(query, k=k)
            if not docs:
                return "No relevant documents found in the knowledge base."

            parts: list[str] = []
            for i, doc in enumerate(docs, start=1):
                source = doc.metadata.get("source", "unknown")
                parts.append(
                    f"--- Chunk {i} (source: {source}) ---\n{doc.page_content}"
                )
            return "\n\n".join(parts)

        self._tools.append(search_knowledge_base)

    def _build_deep_agent(self):
        """Lazily create a deepagents agent with our tools."""
        if self._agent is not None:
            return self._agent

        try:
            from deepagents import create_deep_agent
        except ImportError as exc:
            raise ImportError(
                "deepagents package is required. "
                "Install with: pip install deepagents"
            ) from exc

        # create_deep_agent accepts a model instance or "provider:model" string
        self._agent = create_deep_agent(
            model=self.llm,
            tools=self._tools,
            system_prompt=self.config.system_prompt,
        )
        return self._agent

    # ------------------------------------------------------------------
    # URL ingestion
    # ------------------------------------------------------------------

    def ingest_url(self, url: str) -> int:
        """Fetch, chunk, embed and store a single URL. Returns number of chunks."""
        docs = url_to_documents(
            url,
            chunk_size=self.config.chunk_size,
            chunk_overlap=self.config.chunk_overlap,
        )
        if not docs:
            return 0
        self.vector_manager.add_documents(docs)
        return len(docs)

    def maybe_ingest_from_message(self, message: str) -> List[str]:
        """
        If the message heuristically requests reading a page,
        extract URLs, ingest them, and return the list of ingested URLs.
        """
        if not should_ingest_url(message):
            return []

        urls = extract_urls(message)
        ingested: list[str] = []
        for url in urls:
            try:
                n = self.ingest_url(url)
                if n > 0:
                    ingested.append(url)
                    logger.info("Ingested %d chunks from %s", n, url)
            except Exception as exc:  # noqa: BLE001
                logger.exception("Failed to ingest %s: %s", url, exc)
        return ingested

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def ask(self, user_message: str, use_deep_agent: bool = True) -> str:
        """
        Main entry point for a user question.

        1. Detect & ingest any URLs mentioned in the message.
        2. Run the agent (deep agent or simple retrieval + LLM).
        3. Return the final answer text.
        """
        ingested = self.maybe_ingest_from_message(user_message)
        if ingested:
            prefix = (
                f"[System] Successfully ingested content from: {', '.join(ingested)}. "
                "Use the knowledge base to answer the original question.\n\n"
            )
            user_message = prefix + user_message

        if use_deep_agent:
            try:
                agent = self._build_deep_agent()
                result = agent.invoke(
                    {"messages": [HumanMessage(content=user_message)]}
                )
                last = result["messages"][-1]
                content = getattr(last, "content", None)
                if content is None:
                    content = getattr(last, "text", str(last))
                return content
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "Deep agent failed (%s), falling back to simple RAG", exc
                )

        # Fallback: classic retrieve → generate
        return self._simple_rag(user_message)

    def _simple_rag(self, query: str) -> str:
        """Minimal RAG without deepagents (retrieve + single LLM call)."""
        docs = self.vector_manager.similarity_search(query)
        context = "\n\n".join(
            f"[Source: {d.metadata.get('source', 'unknown')}]\n{d.page_content}"
            for d in docs
        ) or "No relevant context found."

        prompt = (
            f"{self.config.system_prompt}\n\n"
            f"Context from knowledge base:\n{context}\n\n"
            f"User question: {query}\n\n"
            "Answer based on the context when possible. "
            "If the context is insufficient, say so."
        )
        response = self.llm.invoke([HumanMessage(content=prompt)])
        return getattr(response, "content", str(response))

    def search(self, query: str, k: Optional[int] = None) -> List[Document]:
        """Direct vector search (useful for debugging / Telegram handlers)."""
        return self.vector_manager.similarity_search(query, k=k)

    def test_connection(self) -> bool:
        """Verify Pinecone + embeddings connectivity."""
        return self.vector_manager.test_connection()


# ----------------------------------------------------------------------
# Module entry point — connectivity self-test
# ----------------------------------------------------------------------

def _run_self_test() -> None:
    """
    When the module is executed directly (`python rag_agent.py`),
    perform a minimal connectivity check against Pinecone.
    The actual answer content is irrelevant — we only care that the
    pipeline (embed → search) does not raise.
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    print("=" * 60)
    print("RAG Agent — self-test (connection check)")
    print("=" * 60)

    try:
        agent = RAGAgent()
    except ValueError as exc:
        print(f"[FAIL] Configuration error: {exc}")
        print("Make sure OPENAI_API_KEY and PINECONE_API_KEY are set.")
        sys.exit(1)

    ok = agent.test_connection()
    if not ok:
        print("[FAIL] Could not connect to Pinecone or embedding endpoint.")
        sys.exit(1)

    print("[OK] Pinecone + embeddings connection established.")

    # Run a dummy similarity search — answer does not matter
    test_query = "What is retrieval augmented generation?"
    print(f"Running test search: '{test_query}' ...")
    try:
        docs = agent.search(test_query, k=2)
        print(f"[OK] Search returned {len(docs)} document(s).")
        for i, doc in enumerate(docs, 1):
            src = doc.metadata.get("source", "?")
            preview = doc.page_content[:120].replace("\n", " ")
            print(f"  [{i}] source={src} | {preview}...")
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] Search raised (index may be empty): {exc}")
        print("This is acceptable for a fresh empty index.")

    print("=" * 60)
    print("Self-test finished.")
    print("=" * 60)


if __name__ == "__main__":
    _run_self_test()