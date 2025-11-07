#!/bin/bash

# SQLite AI Database Initialization Script
# Creates and initializes SQLite databases for AI/ML workloads
# Usage: ./sqlite-ai-init.sh
#
# This script creates:
# - Conversation history database for chat applications
# - RAG (Retrieval-Augmented Generation) metadata database
# - AI workflow state database for n8n, LangChain, etc.
# - Model performance tracking database

set -e

# Database directory
DB_DIR="${HOME}/.local/share/homelab/databases"
BACKUP_DIR="${HOME}/.local/share/homelab/backups"

# Create directories if they don't exist
mkdir -p "$DB_DIR"
mkdir -p "$BACKUP_DIR"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# ========================================
# 1. Conversation History Database
# ========================================

init_conversations_db() {
    local db_file="$DB_DIR/conversations.db"

    log "Initializing conversation history database..."

    sqlite3 "$db_file" <<'EOF'
-- Conversations table
CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT UNIQUE NOT NULL,
    user_id TEXT,
    model_name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    metadata JSON
);

-- Messages table
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_used INTEGER,
    model_name TEXT,
    metadata JSON,
    FOREIGN KEY (conversation_id) REFERENCES conversations(conversation_id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_conversations_user ON conversations(user_id);
CREATE INDEX IF NOT EXISTS idx_conversations_created ON conversations(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);

-- Enable Write-Ahead Logging for better concurrency
PRAGMA journal_mode=WAL;

-- Performance optimizations
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-64000;  -- 64MB cache
PRAGMA temp_store=MEMORY;
EOF

    log "Conversation history database initialized at: $db_file"
}

# ========================================
# 2. RAG (Retrieval-Augmented Generation) Database
# ========================================

init_rag_db() {
    local db_file="$DB_DIR/rag.db"

    log "Initializing RAG metadata database..."

    sqlite3 "$db_file" <<'EOF'
-- Documents table (metadata only, vectors in Qdrant)
CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    doc_id TEXT UNIQUE NOT NULL,
    title TEXT,
    source TEXT,
    content_hash TEXT,
    file_path TEXT,
    file_type TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON
);

-- Chunks table (text chunks with Qdrant vector IDs)
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chunk_id TEXT UNIQUE NOT NULL,
    doc_id TEXT NOT NULL,
    content TEXT NOT NULL,
    chunk_index INTEGER,
    qdrant_point_id TEXT,  -- ID in Qdrant vector database
    qdrant_collection TEXT,  -- Qdrant collection name
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    FOREIGN KEY (doc_id) REFERENCES documents(doc_id)
);

-- Embeddings metadata (tracks which model generated embeddings)
CREATE TABLE IF NOT EXISTS embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chunk_id TEXT NOT NULL,
    model_name TEXT NOT NULL,
    vector_size INTEGER,
    qdrant_collection TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (chunk_id) REFERENCES chunks(chunk_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_documents_source ON documents(source);
CREATE INDEX IF NOT EXISTS idx_documents_created ON documents(created_at);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);
CREATE INDEX IF NOT EXISTS idx_chunks_qdrant ON chunks(qdrant_point_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_chunk ON embeddings(chunk_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_model ON embeddings(model_name);

-- Full-text search on document content
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    chunk_id UNINDEXED,
    content,
    content=chunks,
    content_rowid=id
);

-- Trigger to keep FTS index updated
CREATE TRIGGER IF NOT EXISTS chunks_fts_insert AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(chunk_id, content) VALUES (new.chunk_id, new.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_fts_update AFTER UPDATE ON chunks BEGIN
    UPDATE chunks_fts SET content = new.content WHERE chunk_id = old.chunk_id;
END;

CREATE TRIGGER IF NOT EXISTS chunks_fts_delete AFTER DELETE ON chunks BEGIN
    DELETE FROM chunks_fts WHERE chunk_id = old.chunk_id;
END;

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-64000;
PRAGMA temp_store=MEMORY;
EOF

    log "RAG metadata database initialized at: $db_file"
}

# ========================================
# 3. AI Workflow State Database
# ========================================

init_workflows_db() {
    local db_file="$DB_DIR/workflows.db"

    log "Initializing AI workflow state database..."

    sqlite3 "$db_file" <<'EOF'
-- Workflow executions
CREATE TABLE IF NOT EXISTS workflow_executions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    execution_id TEXT UNIQUE NOT NULL,
    workflow_name TEXT NOT NULL,
    status TEXT CHECK(status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    error_message TEXT,
    input_data JSON,
    output_data JSON,
    metadata JSON
);

-- Workflow steps
CREATE TABLE IF NOT EXISTS workflow_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    execution_id TEXT NOT NULL,
    step_name TEXT NOT NULL,
    step_index INTEGER,
    status TEXT CHECK(status IN ('pending', 'running', 'completed', 'failed', 'skipped')),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    duration_ms INTEGER,
    error_message TEXT,
    input_data JSON,
    output_data JSON,
    FOREIGN KEY (execution_id) REFERENCES workflow_executions(execution_id)
);

-- AI model calls tracking
CREATE TABLE IF NOT EXISTS model_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    execution_id TEXT,
    model_name TEXT NOT NULL,
    prompt TEXT,
    response TEXT,
    tokens_prompt INTEGER,
    tokens_completion INTEGER,
    tokens_total INTEGER,
    duration_ms INTEGER,
    cost_usd REAL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_executions_workflow ON workflow_executions(workflow_name);
CREATE INDEX IF NOT EXISTS idx_executions_status ON workflow_executions(status);
CREATE INDEX IF NOT EXISTS idx_executions_started ON workflow_executions(started_at);
CREATE INDEX IF NOT EXISTS idx_steps_execution ON workflow_steps(execution_id);
CREATE INDEX IF NOT EXISTS idx_model_calls_execution ON model_calls(execution_id);
CREATE INDEX IF NOT EXISTS idx_model_calls_model ON model_calls(model_name);
CREATE INDEX IF NOT EXISTS idx_model_calls_created ON model_calls(created_at);

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-64000;
PRAGMA temp_store=MEMORY;
EOF

    log "AI workflow state database initialized at: $db_file"
}

# ========================================
# 4. Model Performance Tracking Database
# ========================================

init_performance_db() {
    local db_file="$DB_DIR/model_performance.db"

    log "Initializing model performance tracking database..."

    sqlite3 "$db_file" <<'EOF'
-- Model benchmarks
CREATE TABLE IF NOT EXISTS benchmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_name TEXT NOT NULL,
    task_type TEXT,  -- 'generation', 'embedding', 'classification', etc.
    avg_latency_ms REAL,
    p50_latency_ms REAL,
    p95_latency_ms REAL,
    p99_latency_ms REAL,
    throughput_tokens_per_sec REAL,
    memory_usage_mb REAL,
    gpu_utilization_percent REAL,
    measured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    sample_size INTEGER,
    metadata JSON
);

-- Quality metrics
CREATE TABLE IF NOT EXISTS quality_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_name TEXT NOT NULL,
    task_type TEXT,
    metric_name TEXT,  -- 'accuracy', 'f1', 'bleu', 'rouge', etc.
    metric_value REAL,
    dataset_name TEXT,
    measured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON
);

-- Usage statistics
CREATE TABLE IF NOT EXISTS usage_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_name TEXT NOT NULL,
    date DATE NOT NULL,
    total_requests INTEGER DEFAULT 0,
    total_tokens INTEGER DEFAULT 0,
    total_duration_ms INTEGER DEFAULT 0,
    errors INTEGER DEFAULT 0,
    UNIQUE(model_name, date)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_benchmarks_model ON benchmarks(model_name);
CREATE INDEX IF NOT EXISTS idx_benchmarks_measured ON benchmarks(measured_at);
CREATE INDEX IF NOT EXISTS idx_quality_model ON quality_metrics(model_name);
CREATE INDEX IF NOT EXISTS idx_quality_measured ON quality_metrics(measured_at);
CREATE INDEX IF NOT EXISTS idx_usage_model_date ON usage_stats(model_name, date);

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-64000;
PRAGMA temp_store=MEMORY;
EOF

    log "Model performance tracking database initialized at: $db_file"
}

# ========================================
# Main Execution
# ========================================

header "SQLite AI Database Initialization"

echo ""
log "Database directory: $DB_DIR"
log "Backup directory: $BACKUP_DIR"
echo ""

# Initialize all databases
init_conversations_db
init_rag_db
init_workflows_db
init_performance_db

echo ""
header "Initialization Complete"
echo ""

log "Created databases:"
echo "  - conversations.db     - Chat history and messages"
echo "  - rag.db              - RAG document metadata and chunks"
echo "  - workflows.db        - AI workflow execution state"
echo "  - model_performance.db - Model benchmarks and metrics"
echo ""

log "Databases are configured with:"
echo "  - Write-Ahead Logging (WAL) for better concurrency"
echo "  - 64MB cache for improved performance"
echo "  - Full-text search on RAG document chunks"
echo "  - Optimized indexes for common queries"
echo ""

log "Access databases with:"
echo "  sqlite3 $DB_DIR/<database-name>"
echo ""

log "Integration:"
echo "  - Use with Ollama for conversation history"
echo "  - Use with Qdrant for RAG metadata (text in SQLite, vectors in Qdrant)"
echo "  - Use with n8n/LangChain for workflow state tracking"
echo "  - Track model performance and costs"
echo ""
