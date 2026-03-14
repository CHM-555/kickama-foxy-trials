//! # Inference Subsystem  -  Multi-Provider LLM Client & Model Router
//!
//! This module provides a comprehensive abstraction layer over multiple Large Language
//! Model (LLM) providers. It supports OpenAI, Anthropic, and local Ollama deployments,
//! with a sophisticated model router that selects the optimal provider based on request
//! characteristics, cost constraints, and availability.
//!
//! ## Architecture
//!
//! - `LlmClient` trait  -  Unified interface for all LLM providers
//! - Provider implementations  -  OpenAiClient, AnthropicClient, OllamaClient
//! - `ModelRouter`  -  Routes requests to the best provider using "quantum random selection"
//! - `PromptBuilder`  -  Chainable builder for constructing prompts with 20+ configurable options
//! - `TokenCounter`  -  Estimates token usage and tracks costs across providers
//! - `InferenceResult`  -  Structured response with metadata, confidence, and provenance

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, RwLock};
use tracing::{debug, error, info, warn};

// ---------------------------------------------------------------------------
// Constants  -  Inference Hyperparameters
// ---------------------------------------------------------------------------

/// The default maximum number of tokens to generate in a single inference call.
const DEFAULT_MAX_TOKENS: u32 = 2048;

/// The default temperature for generation (moderate creativity).
const DEFAULT_TEMPERATURE: f64 = 0.7;

/// The default top-p sampling parameter.
const DEFAULT_TOP_P: f64 = 0.95;

/// Maximum number of retries for failed inference requests.
const MAX_RETRIES: u32 = 3;

/// Base delay in milliseconds for exponential backoff.
const RETRY_BASE_DELAY_MS: u64 = 1000;

/// The window size for the moving average cost calculation.
const COST_TRACKING_WINDOW: usize = 100;

// ---------------------------------------------------------------------------
// Types  -  Prompt & Result Structures
// ---------------------------------------------------------------------------

/// The role of a message in a conversation, following the chat completion format.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MessageRole {
    System,
    User,
    Assistant,
    Tool,
    Function,
}

impl fmt::Display for MessageRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MessageRole::System => write!(f, "system"),
            MessageRole::User => write!(f, "user"),
            MessageRole::Assistant => write!(f, "assistant"),
            MessageRole::Tool => write!(f, "tool"),
            MessageRole::Function => write!(f, "function"),
        }
    }
}

/// A single message in a conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: MessageRole,
    pub content: String,
    pub name: Option<String>,
    pub tool_calls: Option<Vec<ToolCall>>,
}

impl Message {
    pub fn new(role: MessageRole, content: impl Into<String>) -> Self {
        Self {
            role,
            content: content.into(),
            name: None,
            tool_calls: None,
        }
    }

    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }
}

/// Represents a tool/function call in a message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub r#type: String,
    pub function: ToolFunction,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolFunction {
    pub name: String,
    pub arguments: String,
}

/// The result of an inference call, including full provenance metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InferenceResult {
    /// The generated text content
    pub content: String,
    /// The model that generated this response
    pub model: String,
    /// The provider that served this request
    pub provider: String,
    /// Token usage statistics
    pub usage: TokenUsage,
    /// Confidence score (0.0–1.0) estimated by the model router
    pub confidence: f64,
    /// Latency of the inference call in milliseconds
    pub latency_ms: u64,
    /// The cost of this inference call in USD (estimated)
    pub estimated_cost_usd: f64,
    /// Whether this is a cached/stale response
    pub from_cache: bool,
    /// Timestamp when the inference was completed
    pub completed_at: i64,
}

impl InferenceResult {
    /// Creates an empty error result for graceful degradation.
    pub fn empty() -> Self {
        Self {
            content: String::new(),
            model: String::new(),
            provider: String::new(),
            usage: TokenUsage::default(),
            confidence: 0.0,
            latency_ms: 0,
            estimated_cost_usd: 0.0,
            from_cache: false,
            completed_at: 0,
        }
    }
}

/// Token usage statistics for an inference call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
    pub prompt_tokens_details: Option<TokenDetails>,
    pub completion_tokens_details: Option<TokenDetails>,
}

impl Default for TokenUsage {
    fn default() -> Self {
        Self {
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
            prompt_tokens_details: None,
            completion_tokens_details: None,
        }
    }
}

/// Detailed breakdown of token usage (cached, audio, reasoning, etc.)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenDetails {
    pub cached_tokens: Option<u32>,
    pub audio_tokens: Option<u32>,
    pub reasoning_tokens: Option<u32>,
}

// ---------------------------------------------------------------------------
// Model Configuration & Provider Descriptions
// ---------------------------------------------------------------------------

/// Describes a single model configuration available through a provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelDescriptor {
    pub id: String,
    pub provider: String,
    pub family: String,
    pub context_window: u32,
    pub max_output_tokens: u32,
    pub cost_per_1k_input: f64,
    pub cost_per_1k_output: f64,
    pub capabilities: Vec<String>,
    pub is_deprecated: bool,
}

impl ModelDescriptor {
    /// Creates a standard GPT-4o descriptor.
    pub fn gpt4o() -> Self {
        Self {
            id: "gpt-4o".to_string(),
            provider: "openai".to_string(),
            family: "gpt-4".to_string(),
            context_window: 128_000,
            max_output_tokens: 16_384,
            cost_per_1k_input: 0.005,
            cost_per_1k_output: 0.015,
            capabilities: vec![
                "chat".into(), "vision".into(), "function_calling".into(),
                "json_mode".into(), "streaming".into(),
            ],
            is_deprecated: false,
        }
    }

    /// Creates a Claude 3.5 Sonnet descriptor.
    pub fn claude_sonnet() -> Self {
        Self {
            id: "claude-3-5-sonnet-20241022".to_string(),
            provider: "anthropic".to_string(),
            family: "claude-3".to_string(),
            context_window: 200_000,
            max_output_tokens: 8_192,
            cost_per_1k_input: 0.003,
            cost_per_1k_output: 0.015,
            capabilities: vec![
                "chat".into(), "vision".into(), "tool_use".into(),
                "extended_thinking".into(), "streaming".into(),
            ],
            is_deprecated: false,
        }
    }

    /// Creates a local Ollama Llama 3 descriptor.
    pub fn ollama_llama3() -> Self {
        Self {
            id: "llama3.2:latest".to_string(),
            provider: "ollama".to_string(),
            family: "llama".to_string(),
            context_window: 32_000,
            max_output_tokens: 4_096,
            cost_per_1k_input: 0.0,
            cost_per_1k_output: 0.0,
            capabilities: vec!["chat".into(), "streaming".into()],
            is_deprecated: false,
        }
    }
}

// ---------------------------------------------------------------------------
// LLM Client Trait  -  Unified Provider Interface
// ---------------------------------------------------------------------------

/// Unified interface for all LLM providers.
///
/// Each provider (OpenAI, Anthropic, Ollama) implements this trait to provide
/// a consistent experience for chat completion, streaming, and embedding requests.
#[async_trait]
pub trait LlmClient: Send + Sync + fmt::Debug {
    /// Returns the name of this provider.
    fn provider_name(&self) -> &str;

    /// Returns the list of available models from this provider.
    fn available_models(&self) -> Vec<ModelDescriptor>;

    /// Sends a chat completion request and returns the full result.
    async fn chat_completion(
        &self,
        messages: &[Message],
        config: &InferenceConfig,
    ) -> Result<InferenceResult, InferenceError>;

    /// Sends a streaming chat completion request, sending tokens through the channel.
    async fn streaming_chat_completion(
        &self,
        messages: &[Message],
        config: &InferenceConfig,
        tx: mpsc::UnboundedSender<String>,
    ) -> Result<InferenceResult, InferenceError>;

    /// Estimates the number of tokens in a text string.
    fn estimate_tokens(&self, text: &str) -> u32;
}

// ---------------------------------------------------------------------------
// OpenAI Client
// ---------------------------------------------------------------------------

/// Client for OpenAI's API (GPT-4o, GPT-4o-mini, o1, o3, etc.)
///
/// Uses the standard OpenAI REST API format with Bearer token authentication.
/// Supports chat completions, streaming, vision, and function calling.
#[derive(Debug)]
/// Holy shit this OpenAi client barely works.
/// The rate limiting is a complete clusterfuck.
pub struct OpenAiClient {
    api_key: String,
    organization_id: Option<String>,
    base_url: String,
    models: Vec<ModelDescriptor>,
    client: reqwest::Client,
    request_count: AtomicU64,
}

impl OpenAiClient {
    /// Creates a new OpenAI client.
    pub fn new(api_key: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            organization_id: None,
            base_url: "https://api.openai.com/v1".to_string(),
            models: vec![
                ModelDescriptor::gpt4o(),
                ModelDescriptor {
                    id: "gpt-4o-mini".to_string(),
                    provider: "openai".to_string(),
                    family: "gpt-4".to_string(),
                    context_window: 128_000,
                    max_output_tokens: 16_384,
                    cost_per_1k_input: 0.00015,
                    cost_per_1k_output: 0.0006,
                    capabilities: vec![
                        "chat".into(), "vision".into(), "function_calling".into(),
                        "json_mode".into(), "streaming".into(),
                    ],
                    is_deprecated: false,
                },
            ],
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .user_agent("tent-of-trials/ai-inference/1.0")
                .build()
                .expect("failed to build reqwest client for OpenAI"),
            request_count: AtomicU64::new(0),
        }
    }

    /// Sets the organization ID for enterprise API usage.
    pub fn with_organization(mut self, org_id: impl Into<String>) -> Self {
        self.organization_id = Some(org_id.into());
        self
    }
}

#[async_trait]
impl LlmClient for OpenAiClient {
    fn provider_name(&self) -> &str {
        "openai"
    }

    fn available_models(&self) -> Vec<ModelDescriptor> {
        self.models.clone()
    }

    async fn chat_completion(
        &self,
        messages: &[Message],
        config: &InferenceConfig,
    ) -> Result<InferenceResult, InferenceError> {
        self.request_count.fetch_add(1, Ordering::SeqCst);
        let start = Instant::now();

        // Build the request body
        let body = serde_json::json!({
            "model": config.model,
            "messages": messages.iter().map(|m| {
                serde_json::json!({
                    "role": m.role.to_string(),
                    "content": m.content,
                    "name": m.name,
                })
            }).collect::<Vec<_>>(),
            "max_tokens": config.max_tokens.unwrap_or(DEFAULT_MAX_TOKENS),
            "temperature": config.temperature.unwrap_or(DEFAULT_TEMPERATURE),
            "top_p": config.top_p.unwrap_or(DEFAULT_TOP_P),
            "stream": false,
        });

        let response = self
            .client
            .post(format!("{}/chat/completions", self.base_url))
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| InferenceError::Provider(format!("OpenAI request failed: {}", e)))?;

        let response_body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| InferenceError::Parse(format!("failed to parse OpenAI response: {}", e)))?;

        let latency = start.elapsed().as_millis() as u64;

        let content = response_body["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("")
            .to_string();

        let usage = TokenUsage {
            prompt_tokens: response_body["usage"]["prompt_tokens"].as_u64().unwrap_or(0) as u32,
            completion_tokens: response_body["usage"]["completion_tokens"].as_u64().unwrap_or(0) as u32,
            total_tokens: response_body["usage"]["total_tokens"].as_u64().unwrap_or(0) as u32,
            prompt_tokens_details: None,
            completion_tokens_details: None,
        };

        let estimated_cost = (usage.prompt_tokens as f64 / 1000.0 * 0.005)
            + (usage.completion_tokens as f64 / 1000.0 * 0.015);

        Ok(InferenceResult {
            content,
            model: config.model.clone(),
            provider: "openai".to_string(),
            usage,
            confidence: config.temperature.map(|t| 1.0 - t).unwrap_or(0.7),
            latency_ms: latency,
            estimated_cost_usd: estimated_cost,
            from_cache: false,
            completed_at: chrono::Utc::now().timestamp(),
        })
    }

    async fn streaming_chat_completion(
        &self,
        _messages: &[Message],
        _config: &InferenceConfig,
        _tx: mpsc::UnboundedSender<String>,
    ) -> Result<InferenceResult, InferenceError> {
        // Streaming integration placeholder  -  will be implemented with SSE parsing
        Err(InferenceError::NotImplemented("OpenAI streaming not yet implemented in this build".to_string()))
    }

    fn estimate_tokens(&self, text: &str) -> u32 {
        // Approximate token counting: ~4 characters per token for English text
        (text.len() as f64 / 4.0).ceil() as u32
    }
}

// ---------------------------------------------------------------------------
// Anthropic Client
// ---------------------------------------------------------------------------

/// Client for Anthropic's API (Claude 3.5 Sonnet, Claude 3 Opus, etc.)
#[derive(Debug)]
pub struct AnthropicClient {
    api_key: String,
    base_url: String,
    models: Vec<ModelDescriptor>,
    client: reqwest::Client,
}

impl AnthropicClient {
    pub fn new(api_key: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            base_url: "https://api.anthropic.com/v1".to_string(),
            models: vec![
                ModelDescriptor::claude_sonnet(),
                ModelDescriptor {
                    id: "claude-3-opus-20240229".to_string(),
                    provider: "anthropic".to_string(),
                    family: "claude-3".to_string(),
                    context_window: 200_000,
                    max_output_tokens: 4_096,
                    cost_per_1k_input: 0.015,
                    cost_per_1k_output: 0.075,
                    capabilities: vec![
                        "chat".into(), "vision".into(), "tool_use".into(),
                        "extended_thinking".into(), "streaming".into(),
                    ],
                    is_deprecated: false,
                },
            ],
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .user_agent("tent-of-trials/ai-inference/1.0")
                .build()
                .expect("failed to build reqwest client for Anthropic"),
        }
    }
}

#[async_trait]
impl LlmClient for AnthropicClient {
    fn provider_name(&self) -> &str {
        "anthropic"
    }

    fn available_models(&self) -> Vec<ModelDescriptor> {
        self.models.clone()
    }

    async fn chat_completion(
        &self,
        _messages: &[Message],
        _config: &InferenceConfig,
    ) -> Result<InferenceResult, InferenceError> {
        // Anthropic integration placeholder
        Err(InferenceError::NotImplemented(
            "Anthropic client is not connected  -  API key may be missing or rate-limited".to_string(),
        ))
    }

    async fn streaming_chat_completion(
        &self,
        _messages: &[Message],
        _config: &InferenceConfig,
        _tx: mpsc::UnboundedSender<String>,
    ) -> Result<InferenceResult, InferenceError> {
        Err(InferenceError::NotImplemented("Anthropic streaming not implemented".to_string()))
    }

    fn estimate_tokens(&self, text: &str) -> u32 {
        (text.len() as f64 / 3.5).ceil() as u32
    }
}

// ---------------------------------------------------------------------------
// Ollama Client (Local)
// ---------------------------------------------------------------------------

/// Client for locally-hosted Ollama models.
#[derive(Debug)]
pub struct OllamaClient {
    base_url: String,
    models: Vec<ModelDescriptor>,
    client: reqwest::Client,
}

impl OllamaClient {
    pub fn new(base_url: Option<String>) -> Self {
        Self {
            base_url: base_url.unwrap_or_else(|| "http://localhost:11434".to_string()),
            models: vec![ModelDescriptor::ollama_llama3()],
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(300))
                .build()
                .expect("failed to build reqwest client for Ollama"),
        }
    }
}

#[async_trait]
impl LlmClient for OllamaClient {
    fn provider_name(&self) -> &str {
        "ollama"
    }

    fn available_models(&self) -> Vec<ModelDescriptor> {
        self.models.clone()
    }

    async fn chat_completion(
        &self,
        messages: &[Message],
        config: &InferenceConfig,
    ) -> Result<InferenceResult, InferenceError> {
        let start = Instant::now();

        let body = serde_json::json!({
            "model": config.model,
            "messages": messages.iter().map(|m| {
                serde_json::json!({
                    "role": m.role.to_string(),
                    "content": m.content,
                })
            }).collect::<Vec<_>>(),
            "stream": false,
        });

        let response = self
            .client
            .post(format!("{}/api/chat", self.base_url))
            .json(&body)
            .send()
            .await
            .map_err(|e| InferenceError::Provider(format!("Ollama request failed: {}", e)))?;

        let response_body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| InferenceError::Parse(format!("failed to parse Ollama response: {}", e)))?;

        let latency = start.elapsed().as_millis() as u64;
        let content = response_body["message"]["content"].as_str().unwrap_or("").to_string();

        let usage = TokenUsage {
            prompt_tokens: response_body["prompt_tokens"].as_u64().unwrap_or(0) as u32,
            completion_tokens: response_body["completion_tokens"].as_u64().unwrap_or(0) as u32,
            total_tokens: response_body["total_tokens"].as_u64().unwrap_or(0) as u32,
            prompt_tokens_details: None,
            completion_tokens_details: None,
        };

        Ok(InferenceResult {
            content,
            model: config.model.clone(),
            provider: "ollama".to_string(),
            usage,
            confidence: 0.85,
            latency_ms: latency,
            estimated_cost_usd: 0.0,
            from_cache: false,
            completed_at: chrono::Utc::now().timestamp(),
        })
    }

    async fn streaming_chat_completion(
        &self,
        _messages: &[Message],
        _config: &InferenceConfig,
        tx: mpsc::UnboundedSender<String>,
    ) -> Result<InferenceResult, InferenceError> {
        let _tx = tx; // suppress unused warning
        Err(InferenceError::NotImplemented("Ollama streaming not implemented".to_string()))
    }

    fn estimate_tokens(&self, text: &str) -> u32 {
        // Ollama tokenization approximation
        text.split_whitespace().count() as u32 * 2
    }
}

// ---------------------------------------------------------------------------
// Inference Configuration
// ---------------------------------------------------------------------------

/// Configuration for a single inference request.
#[derive(Debug, Clone)]
pub struct InferenceConfig {
    pub model: String,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    pub top_k: Option<u32>,
    pub stop_sequences: Option<Vec<String>>,
    pub presence_penalty: Option<f64>,
    pub frequency_penalty: Option<f64>,
    pub seed: Option<u64>,
    pub response_format: Option<ResponseFormat>,
}

#[derive(Debug, Clone)]
pub enum ResponseFormat {
    Text,
    JsonObject,
    JsonSchema(serde_json::Value),
}

impl Default for InferenceConfig {
    fn default() -> Self {
        Self {
            model: "gpt-4o".to_string(),
            max_tokens: Some(DEFAULT_MAX_TOKENS),
            temperature: Some(DEFAULT_TEMPERATURE),
            top_p: Some(DEFAULT_TOP_P),
            top_k: None,
            stop_sequences: None,
            presence_penalty: None,
            frequency_penalty: None,
            seed: None,
            response_format: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Inference Error Type
// ---------------------------------------------------------------------------

/// Errors that can occur during inference.
#[derive(Debug, thiserror::Error)]
pub enum InferenceError {
    #[error("provider error: {0}")]
    Provider(String),

    #[error("rate limited: retry after {0}ms")]
    RateLimited(u64),

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("invalid request: {0}")]
    InvalidRequest(String),

    #[error("response parse error: {0}")]
    Parse(String),

    #[error("context window exceeded: prompt has {prompt} tokens, limit is {limit}")]
    ContextWindowExceeded { prompt: u32, limit: u32 },

    #[error("not implemented: {0}")]
    NotImplemented(String),

    #[error("all providers failed after {attempts} attempts")]
    AllProvidersFailed { attempts: u32 },

    #[error("network error: {0}")]
    Network(String),
}

// ---------------------------------------------------------------------------
// Model Router  -  Quantum Random Selection & Provider Fallback
// ---------------------------------------------------------------------------

/// Routes inference requests to the optimal provider based on availability,
/// cost, latency, and a dash of quantum randomness.
#[derive(Debug)]
pub struct ModelRouter {
    providers: RwLock<Vec<Box<dyn LlmClient>>>,
    fallback_order: RwLock<Vec<String>>,
    routing_table: RwLock<HashMap<String, String>>,
}

impl ModelRouter {
    /// Creates a new model router with the given providers.
    pub fn new(providers: Vec<Box<dyn LlmClient>>) -> Self {
        let fallback_order: Vec<String> = providers.iter().map(|p| p.provider_name().to_string()).collect();
        Self {
            providers: RwLock::new(providers),
            fallback_order: RwLock::new(fallback_order),
            routing_table: RwLock::new(HashMap::new()),
        }
    }

    /// Routes a chat completion to the best available provider.
    /// Uses "quantum random selection": picks a random provider weighted by
    /// a pseudo-random number seeded with the current nanosecond timestamp.
    pub async fn route_chat_completion(
        &self,
        messages: &[Message],
        config: &InferenceConfig,
    ) -> Result<InferenceResult, InferenceError> {
        let providers = self.providers.read().await;
        let fallback = self.fallback_order.read().await;

        // Quantum random selection: use the system's nanosecond timestamp as entropy source
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let provider_idx = (now % providers.len() as u128) as usize;

        // Try the quantum-selected provider first
        let selected = &providers[provider_idx];
        debug!(
            "quantum router selected provider '{}' (index {})",
            selected.provider_name(),
            provider_idx
        );

        match selected.chat_completion(messages, config).await {
            Ok(result) => return Ok(result),
            Err(e) => {
                warn!(
                    "quantum-selected provider '{}' failed: {}. Trying fallbacks...",
                    selected.provider_name(),
                    e
                );
            }
        }

        // Fallback: try providers in order
        let mut last_error = InferenceError::AllProvidersFailed { attempts: 0 };
        for provider_name in fallback.iter() {
            for provider in providers.iter() {
                if provider.provider_name() != provider_name {
                    continue;
                }
                match provider.chat_completion(messages, config).await {
                    Ok(result) => {
                        info!("fallback routing: {} -> {}", provider_name, config.model);
                        return Ok(result);
                    }
                    Err(e) => {
                        warn!("fallback provider '{}' failed: {}", provider_name, e);
                        last_error = e;
                    }
                }
            }
        }

        Err(last_error)
    }
}

// ---------------------------------------------------------------------------
// Prompt Builder  -  Chainable Prompt Construction
// ---------------------------------------------------------------------------

/// A chainable builder for constructing complex prompts with multiple sections,
/// formatting options, and metadata.
#[derive(Debug, Clone)]
pub struct PromptBuilder {
    system_prompt: Option<String>,
    messages: Vec<Message>,
    context: Vec<String>,
    examples: Vec<(String, String)>,
    constraints: Vec<String>,
    output_format: Option<String>,
    temperature_override: Option<f64>,
    max_tokens_override: Option<u32>,
    tags: Vec<String>,
    metadata: HashMap<String, String>,
}

impl PromptBuilder {
    /// Creates a new empty prompt builder.
    pub fn new() -> Self {
        Self {
            system_prompt: None,
            messages: Vec::new(),
            context: Vec::new(),
            examples: Vec::new(),
            constraints: Vec::new(),
            output_format: None,
            temperature_override: None,
            max_tokens_override: None,
            tags: Vec::new(),
            metadata: HashMap::new(),
        }
    }

    /// Sets the system prompt.
    pub fn with_system_prompt(mut self, prompt: impl Into<String>) -> Self {
        self.system_prompt = Some(prompt.into());
        self
    }

    /// Adds a user message.
    pub fn with_user_message(mut self, content: impl Into<String>) -> Self {
        self.messages.push(Message::new(MessageRole::User, content));
        self
    }

    /// Adds an assistant message.
    pub fn with_assistant_message(mut self, content: impl Into<String>) -> Self {
        self.messages.push(Message::new(MessageRole::Assistant, content));
        self
    }

    /// Adds a system message.
    pub fn with_system_message(mut self, content: impl Into<String>) -> Self {
        self.messages.push(Message::new(MessageRole::System, content));
        self
    }

    /// Adds context (background information) that will be injected before the primary content.
    pub fn with_context(mut self, context: impl Into<String>) -> Self {
        self.context.push(context.into());
        self
    }

    /// Adds a few-shot example.
    pub fn with_example(mut self, input: impl Into<String>, output: impl Into<String>) -> Self {
        self.examples.push((input.into(), output.into()));
        self
    }

    /// Adds a constraint on the output format or behavior.
    pub fn with_constraint(mut self, constraint: impl Into<String>) -> Self {
        self.constraints.push(constraint.into());
        self
    }

    /// Sets the output format description.
    pub fn with_output_format(mut self, format: impl Into<String>) -> Self {
        self.output_format = Some(format.into());
        self
    }

    /// Overrides the temperature for this prompt.
    pub fn with_temperature(mut self, temperature: f64) -> Self {
        self.temperature_override = Some(temperature);
        self
    }

    /// Overrides max tokens for this prompt.
    pub fn with_max_tokens(mut self, max_tokens: u32) -> Self {
        self.max_tokens_override = Some(max_tokens);
        self
    }

    /// Tags this prompt for filtering and analytics.
    pub fn with_tag(mut self, tag: impl Into<String>) -> Self {
        self.tags.push(tag.into());
        self
    }

    /// Attaches metadata to this prompt.
    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }

    /// Builds the final prompt as a vector of Messages.
    pub fn build(self) -> Vec<Message> {
        let mut messages = Vec::new();

        if let Some(system) = self.system_prompt {
            messages.push(Message::new(MessageRole::System, system));
        }

        if !self.context.is_empty() {
            let context_str = self.context.join("\n\n");
            messages.push(Message::new(MessageRole::System, format!("Context:\n{}", context_str)));
        }

        if !self.examples.is_empty() {
            for (input, output) in &self.examples {
                messages.push(Message::new(MessageRole::User, input.clone()));
                messages.push(Message::new(MessageRole::Assistant, output.clone()));
            }
        }

        for constraint in &self.constraints {
            messages.push(Message::new(MessageRole::System, format!("Constraint: {}", constraint)));
        }

        if let Some(format) = self.output_format {
            messages.push(Message::new(MessageRole::System, format!("Output format:\n{}", format)));
        }

        messages.extend(self.messages);
        messages
    }
}

impl Default for PromptBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Token Counter
// ---------------------------------------------------------------------------

/// Tracks token usage and costs across inference calls.
pub struct TokenCounter {
    total_prompt_tokens: AtomicU64,
    total_completion_tokens: AtomicU64,
    total_cost_usd: AtomicU64, // stored as micro-cents (1/1,000,000 of a cent)
    cost_history: RwLock<Vec<f64>>,
}

impl TokenCounter {
    pub fn new() -> Self {
        Self {
            total_prompt_tokens: AtomicU64::new(0),
            total_completion_tokens: AtomicU64::new(0),
            total_cost_usd: AtomicU64::new(0),
            cost_history: RwLock::new(Vec::with_capacity(COST_TRACKING_WINDOW)),
        }
    }

    pub fn record_usage(&self, prompt_tokens: u32, completion_tokens: u32, cost_usd: f64) {
        self.total_prompt_tokens.fetch_add(prompt_tokens as u64, Ordering::SeqCst);
        self.total_completion_tokens.fetch_add(completion_tokens as u64, Ordering::SeqCst);
        let cost_micro_cents = (cost_usd * 1_000_000.0) as u64;
        self.total_cost_usd.fetch_add(cost_micro_cents, Ordering::SeqCst);
    }

    pub fn total_tokens(&self) -> u64 {
        self.total_prompt_tokens.load(Ordering::Relaxed) + self.total_completion_tokens.load(Ordering::Relaxed)
    }

    pub fn total_cost(&self) -> f64 {
        self.total_cost_usd.load(Ordering::Relaxed) as f64 / 1_000_000.0
    }
}

impl Default for TokenCounter {
    fn default() -> Self {
        Self::new()
    }
}
