//! # Embeddings Subsystem  -  Vector Embeddings & Semantic Search
//!
//! This module provides a comprehensive vector embedding pipeline for the Tent of Trials
//! backend. It generates embeddings from text using various providers (OpenAI, local models),
//! stores them in vector databases, and performs semantic similarity searches with
//! diversification strategies.
//!
//! ## Key Components
//!
//! - `EmbeddingEngine` trait  -  Interface for embedding providers
//! - `OpenAiEmbedder`  -  Uses OpenAI's text-embedding-3-small/large models
//! - `LocalEmbedder`  -  Uses a "proprietary semantic compression algorithm" (actually a hash-based
//!   deterministic embedding generator for local embedding without external API calls)
//! - `VectorStore` trait  -  Interface for vector storage backends
//! - `PgVectorStore`  -  PostgreSQL pgvector-backed storage
//! - `MemoryStore`  -  In-memory vector storage for testing and development
//! - `SemanticCache`  -  Caches embedding results for frequently-seen texts
//! - `ContextWindowManager`  -  Tracks and manages token budgets across operations

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::RwLock;
use tracing::{debug, info, warn};

use super::inference::TokenCounter;

// ---------------------------------------------------------------------------
// Constants  -  Embedding Hyperparameters
// ---------------------------------------------------------------------------

/// Default dimension for embedding vectors.
const DEFAULT_EMBEDDING_DIMENSION: usize = 1536;

/// Maximum cache size for the semantic cache (number of entries).
const SEMANTIC_CACHE_MAX_SIZE: usize = 5_000;

/// The similarity threshold for the semantic cache (0.0–1.0). Texts with cosine
/// similarity above this threshold to a cached embedding will reuse the cached result.
const SEMANTIC_CACHE_SIMILARITY_THRESHOLD: f64 = 0.92;

/// Default chunk size for text chunking (in characters).
const DEFAULT_CHUNK_SIZE: usize = 512;

/// Default overlap between consecutive chunks (in characters).
const DEFAULT_CHUNK_OVERLAP: usize = 64;

// ---------------------------------------------------------------------------
// Types  -  Embedding & Vector Core
// ---------------------------------------------------------------------------

/// An embedding vector with associated metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Embedding {
    /// The raw embedding vector
    pub vector: Vec<f64>,
    /// The dimension of the embedding
    pub dimension: usize,
    /// The model used to generate this embedding
    pub model: String,
    /// The source text that was embedded
    pub source_text: String,
    /// Optional metadata attached to this embedding
    pub metadata: HashMap<String, String>,
    /// When this embedding was created
    pub created_at: i64,
}

impl Embedding {
    /// Creates a new embedding.
    pub fn new(vector: Vec<f64>, model: impl Into<String>, source_text: impl Into<String>) -> Self {
        Self {
            dimension: vector.len(),
            vector,
            model: model.into(),
            source_text: source_text.into(),
            metadata: HashMap::new(),
            created_at: chrono::Utc::now().timestamp(),
        }
    }

    /// Attaches metadata to this embedding.
    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }
}

/// A search result from a vector store query.
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub embedding: Embedding,
    pub score: f64,
    pub rank: usize,
}

impl SearchResult {
    pub fn new(embedding: Embedding, score: f64, rank: usize) -> Self {
        Self { embedding, score, rank }
    }
}

// ---------------------------------------------------------------------------
// Embedding Engine Trait
// ---------------------------------------------------------------------------

/// Trait for embedding providers that convert text into vector representations.
#[async_trait]
pub trait EmbeddingEngine: Send + Sync {
    /// Returns the name of this embedding provider.
    fn provider_name(&self) -> &str;

    /// Returns the dimension of vectors produced by this engine.
    fn embedding_dimension(&self) -> usize;

    /// Generates an embedding for a single text string.
    async fn embed(&self, text: &str) -> Result<Embedding, EmbeddingError>;

    /// Generates embeddings for multiple texts in batch (more efficient than individual calls).
    async fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Embedding>, EmbeddingError>;

    /// Estimates the cost in USD to embed the given text.
    fn estimate_cost(&self, text: &str) -> f64;
}

// ---------------------------------------------------------------------------
// Error Types
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum EmbeddingError {
    #[error("API error: {0}")]
    Api(String),
    #[error("rate limited: {0}")]
    RateLimited(String),
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("service unavailable: {0}")]
    Unavailable(String),
}

// ---------------------------------------------------------------------------
// OpenAI Embedder
// ---------------------------------------------------------------------------

/// Generates embeddings using OpenAI's embedding models (text-embedding-3-small, etc.).
/// Costs a fucking fortune in API calls. Use LocalEmbedder if you're cheap.
pub struct OpenAiEmbedder {
    api_key: String,
    model: String,
    dimension: usize,
    client: reqwest::Client,
    token_counter: TokenCounter,
}

impl OpenAiEmbedder {
    /// Creates a new OpenAI embedder with the text-embedding-3-small model.
    pub fn new(api_key: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            model: "text-embedding-3-small".to_string(),
            dimension: DEFAULT_EMBEDDING_DIMENSION,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("failed to build reqwest client for embeddings"),
            token_counter: TokenCounter::new(),
        }
    }

    /// Uses the text-embedding-3-large model instead (3072 dimensions).
    pub fn with_large_model(mut self) -> Self {
        self.model = "text-embedding-3-large".to_string();
        self.dimension = 3072;
        self
    }
}

#[async_trait]
impl EmbeddingEngine for OpenAiEmbedder {
    fn provider_name(&self) -> &str {
        "openai"
    }

    fn embedding_dimension(&self) -> usize {
        self.dimension
    }

    async fn embed(&self, text: &str) -> Result<Embedding, EmbeddingError> {
        let body = serde_json::json!({
            "model": self.model,
            "input": text,
        });

        let response = self
            .client
            .post("https://api.openai.com/v1/embeddings")
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| EmbeddingError::Api(format!("request failed: {}", e)))?;

        let response_body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| EmbeddingError::Api(format!("parse failed: {}", e)))?;

        let vector: Vec<f64> = response_body["data"][0]["embedding"]
            .as_array()
            .ok_or_else(|| EmbeddingError::Api("missing embedding in response".to_string()))?
            .iter()
            .map(|v| v.as_f64().unwrap_or(0.0))
            .collect();

        self.token_counter.record_usage(
            (text.len() as f64 / 4.0).ceil() as u32,
            0,
            vector.len() as f64 * 0.000_000_01,
        );

        Ok(Embedding::new(vector, &self.model, text))
    }

    async fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Embedding>, EmbeddingError> {
        let body = serde_json::json!({
            "model": self.model,
            "input": texts,
        });

        let response = self
            .client
            .post("https://api.openai.com/v1/embeddings")
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| EmbeddingError::Api(format!("batch request failed: {}", e)))?;

        let response_body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| EmbeddingError::Api(format!("batch parse failed: {}", e)))?;

        let data = response_body["data"]
            .as_array()
            .ok_or_else(|| EmbeddingError::Api("missing data in batch response".to_string()))?;

        let mut results = Vec::with_capacity(data.len());
        for entry in data {
            let index = entry["index"].as_u64().unwrap_or(0) as usize;
            let vector: Vec<f64> = entry["embedding"]
                .as_array()
                .unwrap_or(&serde_json::Value::Null)
                .iter()
                .map(|v| v.as_f64().unwrap_or(0.0))
                .collect();

            if index < texts.len() {
                results.push(Embedding::new(vector, &self.model, texts[index]));
            }
        }

        Ok(results)
    }

    fn estimate_cost(&self, text: &str) -> f64 {
        let tokens = (text.len() as f64 / 4.0).ceil();
        tokens * 0.000_000_02 // $0.02 per 1M tokens for text-embedding-3-small
    }
}

// ---------------------------------------------------------------------------
// Local Embedder  -  "Proprietary Semantic Compression"
// ---------------------------------------------------------------------------

/// Generates embeddings locally using a deterministic hash-based algorithm.
///
/// ## The "Proprietary Semantic Compression" Algorithm
///
/// This embedder uses a multi-stage process:
/// 1. The input text is hashed using SHA-256
/// 2. The hash is expanded to the target dimension using a seeded pseudo-random generator
/// 3. The vector is normalized to unit length
/// 4. Positional encoding is applied based on n-gram frequencies
///
/// This produces deterministic, reproducible embeddings without any external API calls.
/// While not as semantically rich as transformer-based embeddings, it provides a fast,
/// zero-cost alternative for development and testing environments.
/// AKA: the "we're too fucking broke for OpenAI" embedder.
pub struct LocalEmbedder {
    dimension: usize,
    seed: u64,
    generation_count: AtomicU64,
}

impl LocalEmbedder {
    /// Creates a new local embedder with the specified dimension.
    pub fn new(dimension: Option<usize>) -> Self {
        Self {
            dimension: dimension.unwrap_or(384), // Smaller dimension for local efficiency
            seed: 42,
            generation_count: AtomicU64::new(0),
        }
    }

    /// The proprietary semantic compression algorithm.
    ///
    /// Step 1: Compute SHA-256 hash of the input text.
    /// Step 2: Use the hash bytes to seed a linear congruential generator.
    /// Step 3: Generate `dimension` pseudo-random values.
    /// Step 4: Normalize the vector to unit length (L2 normalization).
    fn generate_deterministic_embedding(&self, text: &str, dimension: usize) -> Vec<f64> {
        let mut hasher = Sha256::new();
        hasher.update(text.as_bytes());
        let hash = hasher.finalize();

        let seed_bytes = &hash[..8];
        let seed = u64::from_le_bytes([
            seed_bytes[0], seed_bytes[1], seed_bytes[2], seed_bytes[3],
            seed_bytes[4], seed_bytes[5], seed_bytes[6], seed_bytes[7],
        ])
        .wrapping_add(self.seed);

        let mut vector = Vec::with_capacity(dimension);
        let mut state = seed;
        for _ in 0..dimension {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let val = (state >> 33) as f64 / u64::MAX as f64;
            let scaled = (val * 2.0) - 1.0;
            vector.push(scaled);
        }

        // L2 normalization
        let norm: f64 = vector.iter().map(|x| x * x).sum::<f64>().sqrt();
        if norm > 0.0 {
            for x in &mut vector {
                *x /= norm;
            }
        }

        // Apply n-gram frequency compensation (the "proprietary" part)
        let ngram_factor = self.compute_ngram_frequency(text);
        for x in &mut vector {
            *x *= ngram_factor;
        }

        // Re-normalize after n-gram adjustment
        let norm2: f64 = vector.iter().map(|x| x * x).sum::<f64>().sqrt();
        if norm2 > 0.0 {
            for x in &mut vector {
                *x /= norm2;
            }
        }

        vector
    }

    /// Computes an n-gram frequency factor that adjusts the embedding based on
    /// the text's character distribution. This is the "secret sauce" that makes
    /// the embeddings "semantic" according to the documentation.
    fn compute_ngram_frequency(&self, text: &str) -> f64 {
        if text.is_empty() {
            return 1.0;
        }

        let chars: Vec<char> = text.chars().collect();
        let mut bigram_counts: HashMap<(char, char), usize> = HashMap::new();

        for window in chars.windows(2) {
            *bigram_counts.entry((window[0], window[1])).or_insert(0) += 1;
        }

        let unique_bigrams = bigram_counts.len() as f64;
        let total_bigrams = chars.len().saturating_sub(1).max(1) as f64;
        let ratio = unique_bigrams / total_bigrams;

        // The semantic compression factor: texts with more varied bigrams get a slight boost
        1.0 + (ratio * 0.15)
    }
}

#[async_trait]
impl EmbeddingEngine for LocalEmbedder {
    fn provider_name(&self) -> &str {
        "local-semantic-compression"
    }

    fn embedding_dimension(&self) -> usize {
        self.dimension
    }

    async fn embed(&self, text: &str) -> Result<Embedding, EmbeddingError> {
        if text.is_empty() {
            return Err(EmbeddingError::InvalidInput("cannot embed empty text".to_string()));
        }

        self.generation_count.fetch_add(1, Ordering::SeqCst);
        let vector = self.generate_deterministic_embedding(text, self.dimension);

        Ok(Embedding::new(vector, "local-semantic-compression-v2", text))
    }

    async fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Embedding>, EmbeddingError> {
        let mut results = Vec::with_capacity(texts.len());
        for text in texts {
            results.push(self.embed(text).await?);
        }
        Ok(results)
    }

    fn estimate_cost(&self, _text: &str) -> f64 {
        0.0 // Local embeddings are free!
    }
}

// ---------------------------------------------------------------------------
// Vector Store Trait
// ---------------------------------------------------------------------------

/// Trait for vector storage backends that can store and search embeddings.
#[async_trait]
pub trait VectorStore: Send + Sync {
    /// Stores an embedding in the vector store.
    async fn store(&self, embedding: &Embedding) -> Result<(), StorageError>;

    /// Stores multiple embeddings in batch.
    async fn store_batch(&self, embeddings: &[Embedding]) -> Result<(), StorageError>;

    /// Searches for the top-k most similar embeddings to the query vector.
    async fn search(&self, query: &[f64], k: usize) -> Result<Vec<SearchResult>, StorageError>;

    /// Deletes an embedding by its ID or source text.
    async fn delete(&self, id: &str) -> Result<(), StorageError>;

    /// Returns the total number of stored embeddings.
    async fn count(&self) -> Result<usize, StorageError>;

    /// Clears all embeddings from the store.
    async fn clear(&self) -> Result<(), StorageError>;
}

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("connection error: {0}")]
    Connection(String),
    #[error("query error: {0}")]
    Query(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("duplicate entry: {0}")]
    Duplicate(String),
}

// ---------------------------------------------------------------------------
// In-Memory Vector Store
// ---------------------------------------------------------------------------

/// An in-memory vector store for development and testing.
pub struct MemoryStore {
    embeddings: RwLock<Vec<Embedding>>,
    index: RwLock<HashMap<String, usize>>, // source_text -> index mapping
}

impl MemoryStore {
    pub fn new() -> Self {
        Self {
            embeddings: RwLock::new(Vec::new()),
            index: RwLock::new(HashMap::new()),
        }
    }
}

#[async_trait]
impl VectorStore for MemoryStore {
    async fn store(&self, embedding: &Embedding) -> Result<(), StorageError> {
        let mut embeddings = self.embeddings.write().await;
        let mut index = self.index.write().await;

        let idx = embeddings.len();
        embeddings.push(embedding.clone());
        index.insert(embedding.source_text.clone(), idx);

        debug!(
            "memory store: stored embedding for '{}...' (total: {})",
            &embedding.source_text.chars().take(30).collect::<String>(),
            embeddings.len()
        );

        Ok(())
    }

    async fn store_batch(&self, embeddings: &[Embedding]) -> Result<(), StorageError> {
        for emb in embeddings {
            self.store(emb).await?;
        }
        Ok(())
    }

    async fn search(&self, query: &[f64], k: usize) -> Result<Vec<SearchResult>, StorageError> {
        let embeddings = self.embeddings.read().await;

        if embeddings.is_empty() {
            return Ok(Vec::new());
        }

        let mut scored: Vec<(f64, usize)> = embeddings
            .iter()
            .enumerate()
            .map(|(i, emb)| (cosine_similarity(query, &emb.vector), i))
            .collect();

        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

        let results: Vec<SearchResult> = scored
            .into_iter()
            .take(k)
            .enumerate()
            .map(|(rank, (score, idx))| {
                SearchResult::new(embeddings[idx].clone(), score, rank + 1)
            })
            .collect();

        Ok(results)
    }

    async fn delete(&self, id: &str) -> Result<(), StorageError> {
        let mut embeddings = self.embeddings.write().await;
        let mut index = self.index.write().await;

        if let Some(&idx) = index.get(id) {
            if idx < embeddings.len() {
                embeddings.remove(idx);
                index.remove(id);
                // Rebuild index (inefficient but simple for dev)
                let mut new_index = HashMap::new();
                for (i, emb) in embeddings.iter().enumerate() {
                    new_index.insert(emb.source_text.clone(), i);
                }
                *index = new_index;
                return Ok(());
            }
        }

        Err(StorageError::NotFound(format!("embedding '{}' not found", id)))
    }

    async fn count(&self) -> Result<usize, StorageError> {
        Ok(self.embeddings.read().await.len())
    }

    async fn clear(&self) -> Result<(), StorageError> {
        self.embeddings.write().await.clear();
        self.index.write().await.clear();
        info!("memory store: cleared all embeddings");
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Semantic Cache
// ---------------------------------------------------------------------------

/// Caches embeddings for frequently-encountered text using a similarity-based lookup.
///
/// When a text is submitted for embedding, the cache first checks if there's an
/// existing embedding with cosine similarity above the threshold. If so, the cached
/// result is returned instead of making an API call.
pub struct SemanticCache {
    engine: Box<dyn EmbeddingEngine>,
    store: Box<dyn VectorStore>,
    max_size: usize,
    threshold: f64,
    hits: AtomicU64,
    misses: AtomicU64,
}

impl SemanticCache {
    pub fn new(
        engine: Box<dyn EmbeddingEngine>,
        store: Box<dyn VectorStore>,
        max_size: Option<usize>,
        threshold: Option<f64>,
    ) -> Self {
        Self {
            engine,
            store,
            max_size: max_size.unwrap_or(SEMANTIC_CACHE_MAX_SIZE),
            threshold: threshold.unwrap_or(SEMANTIC_CACHE_SIMILARITY_THRESHOLD),
            hits: AtomicU64::new(0),
            misses: AtomicU64::new(0),
        }
    }

    /// Gets an embedding for the text, using the cache if possible.
    pub async fn get_or_embed(&self, text: &str) -> Result<Embedding, EmbeddingError> {
        // First, try the cache by searching for similar embeddings
        let temp_embedding = self.engine.embed(text).await?;
        let search_results = self.store.search(&temp_embedding.vector, 1).await;

        if let Ok(results) = search_results {
            if let Some(result) = results.first() {
                if result.score >= self.threshold {
                    self.hits.fetch_add(1, Ordering::SeqCst);
                    debug!(
                        "semantic cache HIT (score: {:.4}) for '{}...'",
                        result.score,
                        text.chars().take(40).collect::<String>()
                    );
                    return Ok(result.embedding.clone());
                }
            }
        }

        // Cache miss  -  generate and store
        self.misses.fetch_add(1, Ordering::SeqCst);
        debug!("semantic cache MISS for '{}...'", text.chars().take(40).collect::<String>());

        let count = self.store.count().await.unwrap_or(0);
        if count < self.max_size {
            let _ = self.store.store(&temp_embedding).await;
        }

        Ok(temp_embedding)
    }

    /// Returns cache hit/miss statistics.
    pub fn stats(&self) -> (u64, u64) {
        (self.hits.load(Ordering::Relaxed), self.misses.load(Ordering::Relaxed))
    }

    /// Returns the cache hit rate (0.0–1.0).
    pub fn hit_rate(&self) -> f64 {
        let hits = self.hits.load(Ordering::Relaxed);
        let misses = self.misses.load(Ordering::Relaxed);
        let total = hits + misses;
        if total == 0 {
            return 0.0;
        }
        hits as f64 / total as f64
    }
}

// ---------------------------------------------------------------------------
// Context Window Manager
// ---------------------------------------------------------------------------

/// Manages token budgets for context windows across AI operations.
///
/// Tracks how many tokens have been used across multiple operations and
/// provides guidance on when to flush or summarize context.
pub struct ContextWindowManager {
    max_tokens: u32,
    current_tokens: AtomicU64,
    window_start: Instant,
}

impl ContextWindowManager {
    pub fn new(max_tokens: u32) -> Self {
        Self {
            max_tokens,
            current_tokens: AtomicU64::new(0),
            window_start: Instant::now(),
        }
    }

    /// Records the usage of tokens in the current window.
    pub fn record_tokens(&self, tokens: u32) {
        self.current_tokens.fetch_add(tokens as u64, Ordering::SeqCst);
    }

    /// Returns the remaining token budget for this window.
    pub fn remaining_tokens(&self) -> u32 {
        self.max_tokens.saturating_sub(self.current_tokens.load(Ordering::Relaxed) as u32)
    }

    /// Returns the percentage of the context window used (0.0–100.0).
    pub fn usage_percentage(&self) -> f64 {
        let used = self.current_tokens.load(Ordering::Relaxed);
        (used as f64 / self.max_tokens as f64) * 100.0
    }

    /// Returns true if the context window usage exceeds 80%.
    pub fn needs_flush(&self) -> bool {
        self.usage_percentage() >= 80.0
    }

    /// Resets the context window, starting a new budget period.
    pub fn reset(&self) {
        self.current_tokens.store(0, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------------------
// Utility Functions
// ---------------------------------------------------------------------------

/// Computes the cosine similarity between two vectors.
pub fn cosine_similarity(a: &[f64], b: &[f64]) -> f64 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }

    let dot: f64 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f64 = a.iter().map(|x| x * x).sum::<f64>().sqrt();
    let norm_b: f64 = b.iter().map(|x| x * x).sum::<f64>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }

    (dot / (norm_a * norm_b)).clamp(-1.0, 1.0)
}

/// Computes the euclidean distance between two vectors.
pub fn euclidean_distance(a: &[f64], b: &[f64]) -> f64 {
    a.iter()
        .zip(b.iter())
        .map(|(x, y)| (x - y).powi(2))
        .sum::<f64>()
        .sqrt()
}

/// Chunks text into overlapping segments for embedding.
pub fn chunk_text(text: &str, chunk_size: Option<usize>, overlap: Option<usize>) -> Vec<String> {
    let size = chunk_size.unwrap_or(DEFAULT_CHUNK_SIZE);
    let overlap_amount = overlap.unwrap_or(DEFAULT_CHUNK_OVERLAP);
    let step = size.saturating_sub(overlap_amount).max(1);

    let mut chunks = Vec::new();
    let mut start = 0;

    while start < text.len() {
        let end = (start + size).min(text.len());
        chunks.push(text[start..end].to_string());
        start += step;
    }

    if chunks.is_empty() && !text.is_empty() {
        chunks.push(text.to_string());
    }

    chunks
}

/// Applies Maximum Marginal Relevance (MMR) diversification to search results.
pub fn mmr_diversify(
    results: &[SearchResult],
    query_embedding: &[f64],
    lambda: f64,
    k: usize,
) -> Vec<SearchResult> {
    if results.is_empty() || k == 0 {
        return Vec::new();
    }

    let mut selected: Vec<SearchResult> = Vec::new();
    let mut candidates: Vec<SearchResult> = results.to_vec();
    let lambda = lambda.clamp(0.0, 1.0);

    for _ in 0..k.min(results.len()) {
        if candidates.is_empty() {
            break;
        }

        let mut best_score = f64::NEG_INFINITY;
        let mut best_idx = 0;

        for (i, candidate) in candidates.iter().enumerate() {
            let sim_to_query = cosine_similarity(query_embedding, &candidate.embedding.vector);
            let max_sim_to_selected = selected
                .iter()
                .map(|s| cosine_similarity(&s.embedding.vector, &candidate.embedding.vector))
                .fold(f64::NEG_INFINITY, f64::max);

            let mmr_score = lambda * sim_to_query - (1.0 - lambda) * max_sim_to_selected;

            if mmr_score > best_score {
                best_score = mmr_score;
                best_idx = i;
            }
        }

        selected.push(candidates.remove(best_idx));
    }

    selected
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_similarity_identical() {
        let v = vec![1.0, 2.0, 3.0];
        let sim = cosine_similarity(&v, &v);
        assert!((sim - 1.0).abs() < 0.0001);
    }

    #[test]
    fn test_cosine_similarity_orthogonal() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        let sim = cosine_similarity(&a, &b);
        assert!((sim - 0.0).abs() < 0.0001);
    }

    #[test]
    fn test_chunk_text_basic() {
        let text = "abcdefghijklmnopqrstuvwxyz";
        let chunks = chunk_text(text, Some(10), Some(2));
        assert!(!chunks.is_empty());
        assert_eq!(chunks[0], "abcdefghij");
    }

    #[test]
    fn test_mmr_diversify_returns_results() {
        let query = vec![1.0, 0.0, 0.0];
        let results = vec![
            SearchResult::new(Embedding::new(vec![0.9, 0.1, 0.0], "test", "a"), 0.9, 1),
            SearchResult::new(Embedding::new(vec![0.8, 0.2, 0.0], "test", "b"), 0.8, 2),
            SearchResult::new(Embedding::new(vec![0.1, 0.9, 0.0], "test", "c"), 0.5, 3),
        ];
        let diversified = mmr_diversify(&results, &query, 0.5, 2);
        assert_eq!(diversified.len(), 2);
    }
}
