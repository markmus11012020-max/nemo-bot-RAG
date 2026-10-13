"""
Telegram bot interface for the RAG Agent (PyTelegramBotAPI).

Capabilities exposed to the user:
  - Answer questions with RAG (vector search → LLM)
  - Automatic URL ingestion when a link is shared
  - Heuristic user memory (facts → embeddings → Pinecone)
  - Explicit commands: /remember, /ingest, /help
"""

from __future__ import annotations

import hashlib
import logging
import os
import sys
import tempfile
import threading
from typing import Optional

try:  # POSIX advisory file locking
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None

try:  # Windows advisory file locking
    import msvcrt
except ImportError:  # pragma: no cover - POSIX
    msvcrt = None

import telebot
from telebot import types

from config import RAGAgentConfig
from memory import UserMemory, should_remember
from rag_agent import RAGAgent
from url_ingestor import extract_urls, should_ingest_url

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("bot")


# ---------------------------------------------------------------------------
# Single-instance lock
# ---------------------------------------------------------------------------

class _SingleInstanceLock:
    """
    Cross-platform advisory lock ensuring only one bot process runs per token.

    Telegram rejects concurrent ``getUpdates`` for the same bot token with
    HTTP 409 ("terminated by other getUpdates request"). This lock makes a
    second instance exit immediately with a clear message instead of fighting
    the first one over the update stream.
    """

    def __init__(self, name: str) -> None:
        import os as _os

        self._path = _os.path.join(tempfile.gettempdir(), f"{name}.lock")
        self._fh = None

    def acquire(self) -> bool:
        """Try to take the lock. Returns False if another instance holds it."""
        self._fh = open(self._path, "w")
        try:
            if fcntl is not None:  # POSIX
                fcntl.flock(self._fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            elif msvcrt is not None:  # Windows
                msvcrt.locking(self._fh.fileno(), msvcrt.LK_NBLCK, 1)
            return True
        except (OSError, IOError):
            self._fh.close()
            self._fh = None
            return False

    def release(self) -> None:
        if self._fh is None:
            return
        try:
            if fcntl is not None:
                fcntl.flock(self._fh, fcntl.LOCK_UN)
            elif msvcrt is not None:
                self._fh.seek(0)
                msvcrt.locking(self._fh.fileno(), msvcrt.LK_UNLCK, 1)
        except (OSError, IOError):
            pass
        finally:
            self._fh.close()
            self._fh = None


def _instance_lock_name(token: str) -> str:
    """Stable, per-token lock file name (does not leak the token itself)."""
    digest = hashlib.sha256(token.encode()).hexdigest()[:16]
    return f"nemo-bot-rag-{digest}"


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def _telegram_token() -> str:
    token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        raise ValueError(
            "TELEGRAM_BOT_TOKEN is not set. "
            "Add it to .env or export it before starting the bot."
        )
    return token


HELP_TEXT = """\
🤖 *Умный RAG-помощник*

Я умею:
• отвечать на вопросы, ища данные в векторной базе
• читать HTML-страницы по ссылкам и сохранять их
• запоминать важные факты о вас (имя, город, предпочтения…)
• принимать новые данные командами или обычным текстом

*Команды*
/start — приветствие
/help — эта справка
/remember <текст> — явно сохранить факт о вас
/ingest <url> — прочитать страницу и добавить в базу
/status — проверка подключения к Pinecone

*Примеры*
• `Меня зовут Иван, живу в Казани`
• `Запомни: я предпочитаю краткие ответы`
• `Прочитай https://example.com и кратко расскажи`
• `Что такое RAG?`
"""

WELCOME_TEXT = """\
Привет! Я умный помощник с RAG.

Задавайте вопросы, кидайте ссылки на статьи — я прочитаю и запомню.
Пишите о себе (имя, город, интересы) — буду учитывать это в ответах.

/help — список команд
"""


class TelegramRAGBot:
    """Thin Telegram layer around RAGAgent + UserMemory."""

    def __init__(
        self,
        token: Optional[str] = None,
        config: Optional[RAGAgentConfig] = None,
    ) -> None:
        self.token = token or _telegram_token()
        self.config = config or RAGAgentConfig()
        # Validate OpenAI / Pinecone; Telegram token checked separately
        self.config.validate()

        self.agent = RAGAgent(self.config)
        self.memory = UserMemory(self.agent.vector_manager)

        self.bot = telebot.TeleBot(self.token, parse_mode="Markdown")
        self._register_handlers()

        # Serialize heavy RAG work so we don't overload the API
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Handlers
    # ------------------------------------------------------------------

    def _register_handlers(self) -> None:
        bot = self.bot

        @bot.message_handler(commands=["start"])
        def cmd_start(message: types.Message) -> None:
            bot.reply_to(message, WELCOME_TEXT)

        @bot.message_handler(commands=["help"])
        def cmd_help(message: types.Message) -> None:
            bot.reply_to(message, HELP_TEXT)

        @bot.message_handler(commands=["status"])
        def cmd_status(message: types.Message) -> None:
            bot.send_chat_action(message.chat.id, "typing")
            ok = self.agent.test_connection()
            if ok:
                bot.reply_to(message, "✅ Pinecone и embeddings доступны.")
            else:
                bot.reply_to(message, "❌ Проблема с подключением. Проверьте ключи в .env.")

        @bot.message_handler(commands=["remember"])
        def cmd_remember(message: types.Message) -> None:
            text = (message.text or "").replace("/remember", "", 1).strip()
            if not text:
                bot.reply_to(
                    message,
                    "Напишите факт после команды:\n`/remember меня зовут Алексей`",
                )
                return
            user_id = str(message.from_user.id)
            n = self.memory.add_raw(user_id, text, category="note")
            bot.reply_to(message, f"💾 Сохранено ({n}).")

        @bot.message_handler(commands=["ingest"])
        def cmd_ingest(message: types.Message) -> None:
            text = (message.text or "").replace("/ingest", "", 1).strip()
            urls = extract_urls(text)
            if not urls:
                bot.reply_to(
                    message,
                    "Укажите URL:\n`/ingest https://example.com/page`",
                )
                return
            bot.send_chat_action(message.chat.id, "typing")
            total = 0
            for url in urls:
                try:
                    n = self.agent.ingest_url(url)
                    total += n
                except Exception as exc:  # noqa: BLE001
                    logger.exception("ingest failed for %s", url)
                    bot.reply_to(message, f"⚠️ Не удалось прочитать {url}: {exc}")
                    return
            bot.reply_to(message, f"📄 Добавлено чанков: {total} из {len(urls)} URL.")

        @bot.message_handler(content_types=["text"])
        def on_text(message: types.Message) -> None:
            self._handle_text(message)

        @bot.message_handler(content_types=["photo", "document", "voice", "sticker"])
        def on_other(message: types.Message) -> None:
            bot.reply_to(
                message,
                "Пока понимаю только текст и ссылки. Напишите вопрос или /help.",
            )

    def _handle_text(self, message: types.Message) -> None:
        text = (message.text or "").strip()
        if not text:
            return

        user_id = str(message.from_user.id)
        chat_id = message.chat.id
        self.bot.send_chat_action(chat_id, "typing")

        try:
            with self._lock:
                reply = self._process_user_message(user_id, text)
        except Exception as exc:  # noqa: BLE001
            logger.exception("Failed to process message from %s", user_id)
            reply = f"Произошла ошибка: {exc}"

        # Telegram message limit ~4096; split if needed
        self._reply_long(message, reply)

    def _process_user_message(self, user_id: str, text: str) -> str:
        """
        Full pipeline:
          1. Heuristic memory extraction & store
          2. URL ingestion if requested
          3. Retrieve user memory + knowledge base
          4. Ask RAG agent with enriched context
        """
        notes: list[str] = []

        # 1) Memory
        saved_facts = self.memory.process_message(user_id, text)
        if saved_facts:
            labels = ", ".join(f"{c}={v}" for c, v in saved_facts[:5])
            notes.append(f"💾 Запомнил: {labels}")

        # 2) URL ingest (also handled inside agent.ask, but we surface feedback)
        if should_ingest_url(text) or extract_urls(text):
            ingested = self.agent.maybe_ingest_from_message(text)
            if ingested:
                notes.append(f"📄 Прочитал и сохранил: {', '.join(ingested)}")

        # 3) Memory context for this query
        memory_ctx = self.memory.format_context(user_id, text, k=5)

        # 4) Enrich the question for the agent
        enriched = text
        if memory_ctx:
            enriched = (
                f"[User memory]\n{memory_ctx}\n\n"
                f"[User question]\n{text}"
            )

        answer = self.agent.ask(enriched, use_deep_agent=True)

        if notes:
            return "\n".join(notes) + "\n\n" + answer
        return answer

    def _reply_long(self, message: types.Message, text: str) -> None:
        """Split long replies into chunks under Telegram limit."""
        limit = 4000
        if len(text) <= limit:
            try:
                self.bot.reply_to(message, text)
            except Exception:
                # Fallback without Markdown if parse fails
                self.bot.reply_to(message, text, parse_mode=None)
            return

        for i in range(0, len(text), limit):
            chunk = text[i : i + limit]
            try:
                if i == 0:
                    self.bot.reply_to(message, chunk)
                else:
                    self.bot.send_message(message.chat.id, chunk)
            except Exception:
                self.bot.send_message(message.chat.id, chunk, parse_mode=None)

    # ------------------------------------------------------------------
    # Run
    # ------------------------------------------------------------------

    def run(self) -> None:
        # Ensure only one instance polls this token; a duplicate would keep
        # triggering Telegram's 409 "terminated by other getUpdates request".
        lock = _SingleInstanceLock(_instance_lock_name(self.token))
        if not lock.acquire():
            logger.error(
                "Another instance of this bot is already running for this token. "
                "Only one poller is allowed by Telegram (error 409). "
                "Stop the other process and try again."
            )
            print(
                "[FAIL] Bot is already running (another instance holds the lock). "
                "Stop it first — Telegram allows only one getUpdates poller per token.",
                file=sys.stderr,
            )
            sys.exit(1)

        try:
            # A leftover webhook also makes getUpdates fail with 409.
            try:
                self.bot.delete_webhook(drop_pending_updates=True)
            except Exception:  # noqa: BLE001
                logger.warning("Could not delete webhook before polling; continuing.")

            logger.info("Starting Telegram bot polling...")
            # infinity_polling handles network blips
            self.bot.infinity_polling(timeout=30, long_polling_timeout=25)
        finally:
            lock.release()


def main() -> None:
    try:
        bot = TelegramRAGBot()
    except ValueError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        sys.exit(1)
    bot.run()


if __name__ == "__main__":
    main()
