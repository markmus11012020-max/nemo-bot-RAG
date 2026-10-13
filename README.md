# Nemo Bot RAG — умный Telegram-помощник

RAG-агент + Telegram (PyTelegramBotAPI) + Pinecone + память о пользователе.

## Возможности

| Функция | Как работает |
|---------|----------------|
| **Ответы на вопросы** | Поиск в Pinecone → LLM (OpenAI-compatible `base_url`) |
| **Чтение URL** | Эвристика / `/ingest` → HTML → чанки → эмбеддинги → Pinecone |
| **Память о пользователе** | Эвристики (имя, город, работа, «запомни…») → эмбеддинги |
| **Добавление данных** | Ссылки, `/remember`, `/ingest`, обычный текст с фактами |
| **Tools** | `@tool`-заглушки под будущие внешние API |

## Структура

```
rag_agent/
├── bot.py            # Telegram-интерфейс (точка входа для продакшена)
├── rag_agent.py      # OOP RAG-агент + self-test
├── memory.py         # эвристическая память пользователя
├── url_ingestor.py   # парсинг HTML-ссылок
├── tools.py          # @tool заглушки
├── config.py         # env-конфиг
├── start.bat / start.sh
├── requirements.txt
└── .env.example
```

## Быстрый старт

```bash
cp .env.example .env
# Заполните: OPENAI_*, PINECONE_*, TELEGRAM_BOT_TOKEN

# Windows
start.bat

# Linux / macOS
bash start.sh
```

Или вручную:

```bash
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python bot.py
```

Токен бота: [@BotFather](https://t.me/BotFather) → `/newbot`.

## Команды в Telegram

| Команда | Описание |
|---------|----------|
| `/start` | Приветствие |
| `/help` | Справка |
| `/remember <текст>` | Явно сохранить факт |
| `/ingest <url>` | Прочитать страницу в базу |
| `/status` | Проверка Pinecone |

Примеры сообщений:

- `Меня зовут Иван, живу в Казани`
- `Запомни: предпочитаю краткие ответы`
- `Прочитай https://docs.langchain.com и кратко расскажи`
- `Что такое RAG?`

## Self-test агента (без Telegram)

```bash
python rag_agent.py
```

## Внешний base_url OpenAI

```env
OPENAI_BASE_URL=https://your-proxy.example.com/v1
OPENAI_API_KEY=sk-...
```
