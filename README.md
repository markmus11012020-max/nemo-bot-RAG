# RAG Agent

Умный RAG-агент на базе **LangChain Deep Agents** + **Pinecone**.

## Возможности

1. **Векторная база Pinecone** — хранение и семантический поиск эмбеддингов.
2. **Tool-функции** (`@tool`) — заглушки для будущих внешних API.
3. **Чтение URL** — эвристическое определение ссылки в сообщении → парсинг страницы → чанки → эмбеддинги → запись в Pinecone → ответ на вопрос.
4. Готов к подключению к Telegram-боту (пока только класс).

## Структура

```
rag_agent/
├── __init__.py
├── config.py          # Конфигурация (env / .env)
├── tools.py           # @tool заглушки
├── url_ingestor.py    # Парсинг URL, чанкинг
├── rag_agent.py       # Основной класс RAGAgent (OOP)
├── requirements.txt
├── .env.example
└── README.md
```

## Быстрый старт

```bash
cd rag_agent
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env
# Заполните OPENAI_API_KEY, OPENAI_BASE_URL, PINECONE_API_KEY и т.д.
```

### Проверка подключения

```bash
python rag_agent.py
```

Скрипт проверит соединение с Pinecone и эмбеддинг-эндпоинтом, выполнит тестовый поиск.

### Использование в коде

```python
from rag_agent import RAGAgent

agent = RAGAgent()

# Обычный вопрос (поиск в векторной БД)
answer = agent.ask("Что такое RAG?")

# Сообщение со ссылкой — страница будет прочитана и проиндексирована
answer = agent.ask(
    "Прочитай эту страницу и кратко расскажи о чём она: "
    "https://docs.langchain.com/oss/python/deepagents/rag"
)

# Прямой поиск
docs = agent.search("retrieval augmented generation", k=3)
```

## Внешний base_url для OpenAI

В `.env`:

```
OPENAI_BASE_URL=https://your-proxy.example.com/v1
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini
OPENAI_EMBEDDING_MODEL=text-embedding-3-small
```

Класс использует `base_url` и для чата, и для эмбеддингов.

## Интеграция с Telegram (позже)

```python
# В хендлере бота:
from rag_agent import RAGAgent

agent = RAGAgent()  # один раз при старте

async def handle_message(update, context):
    text = update.message.text
    reply = agent.ask(text)
    await update.message.reply_text(reply)
```

## Зависимости

См. `requirements.txt`. Основные:

- `deepagents`
- `langchain`, `langchain-openai`, `langchain-pinecone`
- `pinecone`
- `beautifulsoup4`, `lxml`, `requests`
