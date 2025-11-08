# AI Stack Integration Examples

This document provides practical examples for using Qdrant (vector database) and SQLite (metadata database) together in AI/ML workflows with Ollama, LangChain, and other AI services.

## Table of Contents

1. [Setup](#setup)
2. [RAG (Retrieval-Augmented Generation)](#rag-retrieval-augmented-generation)
3. [Conversation History](#conversation-history)
4. [Semantic Search](#semantic-search)
5. [Workflow Tracking](#workflow-tracking)
6. [Model Performance Monitoring](#model-performance-monitoring)

## Setup

### Prerequisites

```bash
# Install Python dependencies
pip install qdrant-client sentence-transformers langchain openai

# Initialize SQLite databases
./sqlite-ai-init.sh

# Verify Qdrant is running
curl http://qdrant.home:6333/collections
```

### Environment Variables

```bash
export QDRANT_URL="http://qdrant.home:6333"
export QDRANT_API_KEY="your-api-key-from-env"
export OLLAMA_URL="http://ollama.home:11434"
export SQLITE_DB_DIR="$HOME/.local/share/homelab/databases"
```

## RAG (Retrieval-Augmented Generation)

Complete example of building a RAG system with Qdrant for vectors and SQLite for metadata.

### Python Example

```python
import sqlite3
import uuid
from typing import List, Dict
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct
from sentence_transformers import SentenceTransformer

# Configuration
QDRANT_URL = "http://qdrant.home:6333"
QDRANT_API_KEY = "your-api-key"
SQLITE_DB = "~/.local/share/homelab/databases/rag.db"
COLLECTION_NAME = "documents"
VECTOR_SIZE = 384  # all-MiniLM-L6-v2 embedding size

# Initialize clients
qdrant_client = QdrantClient(
    url=QDRANT_URL,
    api_key=QDRANT_API_KEY,
)

embedding_model = SentenceTransformer('all-MiniLM-L6-v2')

sqlite_conn = sqlite3.connect(SQLITE_DB)
sqlite_cursor = sqlite_conn.cursor()

# Step 1: Create Qdrant collection
qdrant_client.create_collection(
    collection_name=COLLECTION_NAME,
    vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
)

# Step 2: Add documents to RAG system
def add_document(title: str, content: str, source: str, metadata: Dict = None):
    """Add a document to both SQLite (metadata) and Qdrant (vectors)"""

    doc_id = str(uuid.uuid4())

    # Insert document metadata into SQLite
    sqlite_cursor.execute("""
        INSERT INTO documents (doc_id, title, source, metadata)
        VALUES (?, ?, ?, ?)
    """, (doc_id, title, source, str(metadata or {})))

    # Chunk the document (simple splitting by sentences)
    chunks = content.split('. ')
    points = []

    for idx, chunk in enumerate(chunks):
        if not chunk.strip():
            continue

        chunk_id = f"{doc_id}-{idx}"

        # Generate embedding
        vector = embedding_model.encode(chunk).tolist()

        # Store chunk metadata in SQLite
        sqlite_cursor.execute("""
            INSERT INTO chunks (chunk_id, doc_id, content, chunk_index,
                              qdrant_point_id, qdrant_collection)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (chunk_id, doc_id, chunk, idx, chunk_id, COLLECTION_NAME))

        # Prepare point for Qdrant
        points.append(PointStruct(
            id=chunk_id,
            vector=vector,
            payload={
                "doc_id": doc_id,
                "title": title,
                "chunk_index": idx,
                "content": chunk,
                "source": source,
            }
        ))

    # Batch insert vectors into Qdrant
    qdrant_client.upsert(
        collection_name=COLLECTION_NAME,
        points=points
    )

    sqlite_conn.commit()
    return doc_id

# Step 3: Search documents
def search_documents(query: str, limit: int = 5):
    """Search for relevant document chunks"""

    # Generate query embedding
    query_vector = embedding_model.encode(query).tolist()

    # Search Qdrant for similar vectors
    search_results = qdrant_client.search(
        collection_name=COLLECTION_NAME,
        query_vector=query_vector,
        limit=limit,
    )

    # Enrich results with SQLite metadata
    results = []
    for result in search_results:
        chunk_id = result.id

        # Get full metadata from SQLite
        sqlite_cursor.execute("""
            SELECT c.content, c.chunk_index, d.title, d.source
            FROM chunks c
            JOIN documents d ON c.doc_id = d.doc_id
            WHERE c.chunk_id = ?
        """, (chunk_id,))

        row = sqlite_cursor.fetchone()
        if row:
            results.append({
                "content": row[0],
                "chunk_index": row[1],
                "title": row[2],
                "source": row[3],
                "score": result.score,
            })

    return results

# Step 4: RAG query with Ollama
def rag_query(question: str):
    """Ask a question using RAG with Ollama"""
    import requests

    # Retrieve relevant context
    context_chunks = search_documents(question, limit=3)
    context = "\n\n".join([c["content"] for c in context_chunks])

    # Build prompt with context
    prompt = f"""Context:
{context}

Question: {question}

Answer based on the context above:"""

    # Call Ollama
    response = requests.post(
        "http://ollama.home:11434/api/generate",
        json={
            "model": "qwen3:8b",
            "prompt": prompt,
            "stream": False,
        }
    )

    return response.json()["response"]

# Example usage
if __name__ == "__main__":
    # Add a sample document
    add_document(
        title="AI Homelab Setup",
        content="Your homelab runs Ollama for LLMs. Qdrant stores vectors. "
                "SQLite stores metadata. LangChain orchestrates workflows.",
        source="documentation",
    )

    # Search
    results = search_documents("How do I store vectors?")
    for r in results:
        print(f"[{r['score']:.3f}] {r['title']}: {r['content']}")

    # RAG query
    answer = rag_query("What database stores vectors?")
    print(f"\nAnswer: {answer}")
```

## Conversation History

Track chat conversations in SQLite with embeddings in Qdrant for semantic search.

```python
import sqlite3
import requests
from datetime import datetime

SQLITE_DB = "~/.local/share/homelab/databases/conversations.db"
OLLAMA_URL = "http://ollama.home:11434"

conn = sqlite3.connect(SQLITE_DB)
cursor = conn.cursor()

def create_conversation(user_id: str, title: str = None):
    """Create a new conversation"""
    import uuid
    conversation_id = str(uuid.uuid4())

    cursor.execute("""
        INSERT INTO conversations (conversation_id, user_id, title)
        VALUES (?, ?, ?)
    """, (conversation_id, user_id, title))

    conn.commit()
    return conversation_id

def add_message(conversation_id: str, role: str, content: str, model_name: str = "qwen3:8b"):
    """Add a message to the conversation"""
    cursor.execute("""
        INSERT INTO messages (conversation_id, role, content, model_name)
        VALUES (?, ?, ?, ?)
    """, (conversation_id, role, content, model_name))

    conn.commit()

def get_conversation_history(conversation_id: str, limit: int = 20):
    """Retrieve conversation history"""
    cursor.execute("""
        SELECT role, content, created_at
        FROM messages
        WHERE conversation_id = ?
        ORDER BY created_at DESC
        LIMIT ?
    """, (conversation_id, limit))

    return cursor.fetchall()

def chat_with_history(conversation_id: str, user_message: str):
    """Send a message and get response with conversation history"""

    # Add user message
    add_message(conversation_id, "user", user_message)

    # Get conversation history
    history = get_conversation_history(conversation_id)

    # Build messages for Ollama
    messages = []
    for role, content, _ in reversed(history):
        messages.append({"role": role, "content": content})

    # Call Ollama chat endpoint
    response = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": "qwen3:8b",
            "messages": messages,
            "stream": False,
        }
    )

    assistant_response = response.json()["message"]["content"]

    # Save assistant response
    add_message(conversation_id, "assistant", assistant_response)

    return assistant_response

# Example usage
conv_id = create_conversation("user123", "Homelab Setup Help")
response = chat_with_history(conv_id, "How do I set up Ollama?")
print(response)
```

## Semantic Search

Use Qdrant for semantic search with SQLite for full-text search fallback.

```python
# Hybrid search: Vector similarity + full-text search

def hybrid_search(query: str, use_fts: bool = True, limit: int = 10):
    """Perform hybrid search using both vector and full-text search"""

    # Vector search in Qdrant
    query_vector = embedding_model.encode(query).tolist()
    vector_results = qdrant_client.search(
        collection_name="documents",
        query_vector=query_vector,
        limit=limit,
    )

    vector_chunk_ids = [r.id for r in vector_results]

    # Full-text search in SQLite
    if use_fts:
        cursor.execute("""
            SELECT chunk_id, rank
            FROM chunks_fts
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        """, (query, limit))

        fts_chunk_ids = [row[0] for row in cursor.fetchall()]
    else:
        fts_chunk_ids = []

    # Combine and rank results
    combined_ids = list(set(vector_chunk_ids + fts_chunk_ids))

    # Retrieve full metadata
    placeholders = ','.join('?' * len(combined_ids))
    cursor.execute(f"""
        SELECT c.chunk_id, c.content, d.title, d.source
        FROM chunks c
        JOIN documents d ON c.doc_id = d.doc_id
        WHERE c.chunk_id IN ({placeholders})
    """, combined_ids)

    return cursor.fetchall()
```

## Workflow Tracking

Track AI workflow executions in SQLite for monitoring and debugging.

```python
import sqlite3
import time
from typing import Dict, Any

WORKFLOWS_DB = "~/.local/share/homelab/databases/workflows.db"

class WorkflowTracker:
    def __init__(self):
        self.conn = sqlite3.connect(WORKFLOWS_DB)
        self.cursor = self.conn.cursor()

    def start_execution(self, workflow_name: str, input_data: Dict) -> str:
        """Start tracking a workflow execution"""
        import uuid
        execution_id = str(uuid.uuid4())

        self.cursor.execute("""
            INSERT INTO workflow_executions
            (execution_id, workflow_name, status, input_data)
            VALUES (?, ?, 'running', ?)
        """, (execution_id, workflow_name, str(input_data)))

        self.conn.commit()
        return execution_id

    def complete_execution(self, execution_id: str, output_data: Dict):
        """Mark execution as completed"""
        self.cursor.execute("""
            UPDATE workflow_executions
            SET status = 'completed',
                completed_at = CURRENT_TIMESTAMP,
                output_data = ?
            WHERE execution_id = ?
        """, (str(output_data), execution_id))

        self.conn.commit()

    def track_model_call(self, execution_id: str, model_name: str,
                        prompt: str, response: str, duration_ms: int):
        """Track an AI model API call"""
        self.cursor.execute("""
            INSERT INTO model_calls
            (execution_id, model_name, prompt, response, duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, (execution_id, model_name, prompt, response, duration_ms))

        self.conn.commit()

# Example usage
tracker = WorkflowTracker()

execution_id = tracker.start_execution(
    "document_summary",
    {"document_id": "doc123"}
)

start = time.time()
# Call Ollama...
response = "Summary of document..."
duration_ms = int((time.time() - start) * 1000)

tracker.track_model_call(
    execution_id,
    "qwen3:8b",
    "Summarize this document...",
    response,
    duration_ms
)

tracker.complete_execution(execution_id, {"summary": response})
```

## Model Performance Monitoring

Track model performance metrics over time.

```python
import sqlite3
from datetime import date

PERF_DB = "~/.local/share/homelab/databases/model_performance.db"

def record_usage(model_name: str, tokens: int, duration_ms: int, error: bool = False):
    """Record model usage statistics"""
    conn = sqlite3.connect(PERF_DB)
    cursor = conn.cursor()

    today = date.today()

    cursor.execute("""
        INSERT INTO usage_stats (model_name, date, total_requests, total_tokens, total_duration_ms, errors)
        VALUES (?, ?, 1, ?, ?, ?)
        ON CONFLICT(model_name, date) DO UPDATE SET
            total_requests = total_requests + 1,
            total_tokens = total_tokens + ?,
            total_duration_ms = total_duration_ms + ?,
            errors = errors + ?
    """, (model_name, today, tokens, duration_ms, 1 if error else 0,
          tokens, duration_ms, 1 if error else 0))

    conn.commit()
    conn.close()

def get_model_stats(model_name: str, days: int = 7):
    """Get model usage statistics for the past N days"""
    conn = sqlite3.connect(PERF_DB)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT date, total_requests, total_tokens,
               total_duration_ms, errors
        FROM usage_stats
        WHERE model_name = ?
        AND date >= date('now', ?)
        ORDER BY date DESC
    """, (model_name, f'-{days} days'))

    return cursor.fetchall()
```

## Integration with n8n

Use these databases in n8n workflows:

### n8n SQLite Node

```javascript
// In n8n SQLite node, execute query:
SELECT * FROM conversations WHERE user_id = {{ $json.userId }}
```

### n8n HTTP Request to Qdrant

```javascript
// Search Qdrant from n8n
{
  "method": "POST",
  "url": "http://qdrant.home:6333/collections/documents/points/search",
  "headers": {
    "api-key": "{{ $env.QDRANT_API_KEY }}"
  },
  "body": {
    "vector": {{ $json.embedding }},
    "limit": 5
  }
}
```

## Next Steps

1. Explore LangChain integration with these databases
2. Build custom RAG applications
3. Create monitoring dashboards for model performance
4. Implement vector caching strategies
5. Add automated backup workflows

## Resources

- [Qdrant Documentation](https://qdrant.tech/documentation/)
- [SQLite Full-Text Search](https://www.sqlite.org/fts5.html)
- [LangChain Qdrant Integration](https://python.langchain.com/docs/integrations/vectorstores/qdrant)
- [Sentence Transformers](https://www.sbert.net/)
