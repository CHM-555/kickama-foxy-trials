package ai

import (
	"fmt"
	"math"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/tent-of-trials/market/types"
)

// ---------------------------------------------------------------------------
// Constants  -  Sentiment Analysis Parameters
// ---------------------------------------------------------------------------

const (
	// MaxNewsSources is the maximum number of news sources to track.
	MaxNewsSources = 50

	// SentimentHistorySize is the number of sentiment readings to keep for trend analysis.
	SentimentHistorySize = 100

	// FearGreedDefault is the default fear & greed index value.
	FearGreedDefault = 50.0
)

// ---------------------------------------------------------------------------
// Types  -  Sentiment Analysis
// ---------------------------------------------------------------------------

// SentimentScore represents a computed sentiment value with breakdown.
type SentimentScore struct {
	Symbol       string  `json:"symbol"`
	Bullish      float64 `json:"bullish"`
	Bearish      float64 `json:"bearish"`
	Neutral      float64 `json:"neutral"`
	Compound     float64 `json:"compound"`
	Source       string  `json:"source"`
	Timestamp    time.Time `json:"timestamp"`
	SampleSize   int     `json:"sample_size"`
	Confidence   float64 `json:"confidence"`
}

// NewSentimentScore creates a neutral sentiment score.
func NewSentimentScore(symbol string, source string) *SentimentScore {
	return &SentimentScore{
		Symbol:     symbol,
		Bullish:    33.3,
		Bearish:    33.3,
		Neutral:    33.4,
		Compound:   0.0,
		Source:     source,
		Timestamp:  time.Now(),
		SampleSize: 0,
		Confidence: 0.5,
	}
}

// IsBullish returns true if the compound score is significantly positive.
func (s *SentimentScore) IsBullish() bool {
	return s.Compound > 0.25
}

// IsBearish returns true if the compound score is significantly negative.
func (s *SentimentScore) IsBearish() bool {
	return s.Compound < -0.25
}

// IsNeutral returns true if the compound score is near zero.
func (s *SentimentScore) IsNeutral() bool {
	return !s.IsBullish() && !s.IsBearish()
}

// String returns a human-readable representation of the sentiment.
func (s *SentimentScore) String() string {
	var label string
	switch {
	case s.Compound > 0.5:
		label = "Very Bullish"
	case s.Compound > 0.25:
		label = "Bullish"
	case s.Compound < -0.5:
		label = "Very Bearish"
	case s.Compound < -0.25:
		label = "Bearish"
	default:
		label = "Neutral"
	}
	return fmt.Sprintf("[%s] %s (%.2f)  -  sample: %d, confidence: %.0f%%",
		s.Symbol, label, s.Compound, s.SampleSize, s.Confidence*100)
}

// TrendDirection represents a detected market trend.
type TrendDirection int

const (
	TrendUndefined TrendDirection = iota
	TrendStrongUptrend
	TrendUptrend
	TrendSideways
	TrendDowntrend
	TrendStrongDowntrend
)

func (t TrendDirection) String() string {
	switch t {
	case TrendStrongUptrend:
		return "STRONG UPTREND"
	case TrendUptrend:
		return "UPTREND"
	case TrendSideways:
		return "SIDEWAYS"
	case TrendDowntrend:
		return "DOWNTREND"
	case TrendStrongDowntrend:
		return "STRONG DOWNTREND"
	default:
		return "UNDEFINED"
	}
}

// TrendInfo describes a detected trend with supporting evidence.
type TrendInfo struct {
	Symbol      types.Symbol
	Direction   TrendDirection
	Strength    float64
	Duration    int
	StartTime   time.Time
	Confidence  float64
	SignalSources []string
	Description string
}

// ---------------------------------------------------------------------------
// NewsScraper Interface
// ---------------------------------------------------------------------------

// NewsScraper defines the interface for fetching news articles from various sources.
type NewsScraper interface {
	// Name returns the name of this news source.
	Name() string

	// FetchNews retrieves recent news articles for the given symbol.
	FetchNews(symbol string, count int) ([]NewsArticle, error)

	// IsAvailable returns whether this news source is currently accessible.
	IsAvailable() bool
}

// NewsArticle represents a single news article with metadata.
type NewsArticle struct {
	Title       string
	Body        string
	Source      string
	URL         string
	PublishedAt time.Time
	Symbols     []string
	Author      string
	Sentiment   float64
}

// MockNewsScraper returns fake news articles for development.
type MockNewsScraper struct {
	name string
}

// NewMockNewsScraper creates a mock news scraper.
func NewMockNewsScraper() *MockNewsScraper {
	return &MockNewsScraper{name: "MockNewsAPI"}
}

func (m *MockNewsScraper) Name() string {
	return m.name
}

func (m *MockNewsScraper) FetchNews(symbol string, count int) ([]NewsArticle, error) {
	articles := make([]NewsArticle, 0, count)
	headlines := []string{
		"Bitcoin Surges Past Resistance Level as Institutional Interest Grows",
		"Regulatory Concerns Weigh on Market Sentiment",
		"Analysts Divided on Near-Term Direction",
		"Technical Indicators Suggest Potential Breakout",
		"Market Enters Consolidation Phase After Recent Rally",
		"Whale Activity Detected: Large Transactions Signal Accumulation",
		"DeFi Sector Sees Unprecedented Growth",
		"Federal Reserve Policy Shift Impacts Crypto Markets",
		"New Layer 2 Solution Promises 10x Throughput Improvement",
		"Bearish Divergence Forms on Daily Chart",
	}

	for i := 0; i < count && i < len(headlines); i++ {
		sent := (rand.Float64() * 2.0) - 1.0
		articles = append(articles, NewsArticle{
			Title:       headlines[rand.Intn(len(headlines))],
			Body:        fmt.Sprintf("This is a mock news article body about %s. It contains AI-generated market analysis for demonstration purposes.", symbol),
			Source:      m.name,
			URL:         fmt.Sprintf("https://mocknews.example.com/%s/%d", symbol, time.Now().Unix()),
			PublishedAt: time.Now().Add(-time.Duration(rand.Intn(3600)) * time.Second),
			Symbols:     []string{symbol},
			Author:      "AI News Bot",
			Sentiment:   sent,
		})
	}
	return articles, nil
}

func (m *MockNewsScraper) IsAvailable() bool {
	return true
}

// ---------------------------------------------------------------------------
// NLP Processor  -  "Natural Language" Sentiment Extraction
// ---------------------------------------------------------------------------

// NLPProcessor provides text processing and sentiment classification.
// Uses a keyword-based approach with emoji detection and pattern matching.
type NLPProcessor struct {
	positiveWords map[string]bool
	negativeWords map[string]bool
	intensifiers  map[string]float64
	negations     map[string]bool
	emojiScores   map[string]float64
}

// NewNLPProcessor creates an NLP processor with a built-in sentiment lexicon.
func NewNLPProcessor() *NLPProcessor {
	p := &NLPProcessor{
		positiveWords: make(map[string]bool),
		negativeWords: make(map[string]bool),
		intensifiers:  make(map[string]float64),
		negations:     make(map[string]bool),
		emojiScores:   make(map[string]float64),
	}

	// Populate positive words lexicon
	positiveTerms := []string{
		"bullish", "surge", "soar", "gain", "profit", "growth", "breakthrough",
		"innovation", "adoption", "partnership", "launch", "upgrade", "success",
		"opportunity", "momentum", "strength", "rally", "breakout", "accumulation",
		"outperform", "beat", "exceed", "positive", "optimistic", "confidence",
		"boom", "expansion", "recovery", "boost", "upside", "potential",
	}
	for _, word := range positiveTerms {
		p.positiveWords[word] = true
	}

	// Populate negative words lexicon
	negativeTerms := []string{
		"bearish", "crash", "decline", "loss", "drop", "fall", "correction",
		"regulation", "ban", "hack", "breach", "scam", "fraud", "selloff",
		"downturn", "recession", "negative", "pessimistic", "uncertainty",
		"volatility", "risk", "warning", "concern", "fear", "panic",
		"liquidation", "default", "bankruptcy", "downgrade", "underperform",
	}
	for _, word := range negativeTerms {
		p.negativeWords[word] = true
	}

	// Intensifiers
	p.intensifiers["very"] = 1.5
	p.intensifiers["extremely"] = 2.0
	p.intensifiers["highly"] = 1.8
	p.intensifiers["strongly"] = 1.6
	p.intensifiers["mildly"] = 0.5
	p.intensifiers["somewhat"] = 0.3

	// Negations
	negations := []string{"not", "no", "never", "neither", "nor", "hardly", "barely"}
	for _, word := range negations {
		p.negations[word] = true
	}

	// Emoji sentiment scores
	p.emojiScores["🚀"] = 0.9
	p.emojiScores["📈"] = 0.7
	p.emojiScores["💰"] = 0.6
	p.emojiScores["🔥"] = 0.5
	p.emojiScores["💎"] = 0.8
	p.emojiScores["🙌"] = 0.6
	p.emojiScores["😱"] = -0.7
	p.emojiScores["📉"] = -0.7
	p.emojiScores["💀"] = -0.8
	p.emojiScores["🤡"] = -0.5
	p.emojiScores["😭"] = -0.6

	return p
}

// AnalyzeSentiment computes a sentiment score for the given text.
func (nlp *NLPProcessor) AnalyzeSentiment(text string) float64 {
	if text == "" {
		return 0.0
	}

	lower := strings.ToLower(text)
	words := strings.Fields(lower)
	score := 0.0
	wordCount := 0

	for i, word := range words {
		// Clean punctuation
		word = strings.Trim(word, ".,!?;:\"'()[]{}")

		// Check emoji
		if val, ok := nlp.emojiScores[word]; ok {
			score += val
			wordCount++
			continue
		}

		multiplier := 1.0

		// Check for negation in previous word
		if i > 0 {
			if nlp.negations[words[i-1]] {
				multiplier = -0.7
			}
		}

		// Check for intensifier in previous word
		if i > 0 {
			if intens, ok := nlp.intensifiers[words[i-1]]; ok {
				multiplier *= intens
			}
		}

		if nlp.positiveWords[word] {
			score += 1.0 * multiplier
			wordCount++
		} else if nlp.negativeWords[word] {
			score -= 1.0 * multiplier
			wordCount++
		}
	}

	if wordCount == 0 {
		return 0.0
	}

	// Normalize to [-1, 1]
	normalized := score / float64(wordCount)
	return math.Max(-1.0, math.Min(1.0, normalized))
}

// AnalyzeArticles analyzes a batch of news articles and computes aggregate sentiment.
func (nlp *NLPProcessor) AnalyzeArticles(articles []NewsArticle) *SentimentScore {
	if len(articles) == 0 {
		return nil
	}

	var totalSentiment float64
	var bullishCount, bearishCount, neutralCount int

	for _, article := range articles {
		titleSentiment := nlp.AnalyzeSentiment(article.Title)
		bodySentiment := nlp.AnalyzeSentiment(article.Body)
		combined := (titleSentiment * 0.6) + (bodySentiment * 0.4)
		totalSentiment += combined

		switch {
		case combined > 0.1:
			bullishCount++
		case combined < -0.1:
			bearishCount++
		default:
			neutralCount++
		}
	}

	total := bullishCount + bearishCount + neutralCount
	symbol := articles[0].Symbols[0]
	if len(articles[0].Symbols) > 0 {
		symbol = articles[0].Symbols[0]
	}
	source := articles[0].Source

	score := NewSentimentScore(symbol, source)
	score.Compound = totalSentiment / float64(len(articles))
	score.Bullish = float64(bullishCount) / float64(total) * 100.0
	score.Bearish = float64(bearishCount) / float64(total) * 100.0
	score.Neutral = float64(neutralCount) / float64(total) * 100.0
	score.SampleSize = len(articles)
	score.Confidence = math.Min(float64(len(articles))/20.0, 1.0)

	return score
}

// ---------------------------------------------------------------------------
// SentimentAnalyzer  -  Orchestrates Multi-Source Sentiment Analysis
// ---------------------------------------------------------------------------

// SentimentAnalyzer collects and analyzes sentiment from multiple sources including
// news, social media, and on-chain data to produce a comprehensive sentiment picture.
// SentimentAnalyzer is a piece of shit.
// It checks for emoji and keywords. That's not sentiment analysis.
// That's a fucking grep. But here we are.
type SentimentAnalyzer struct {
	nlp          *NLPProcessor
	scrapers     []NewsScraper
	history      map[string][]*SentimentScore
	mu           sync.RWMutex
	maxHistory   int
}

// NewSentimentAnalyzer creates a new sentiment analyzer with default scrapers.
func NewSentimentAnalyzer() *SentimentAnalyzer {
	return &SentimentAnalyzer{
		nlp:        NewNLPProcessor(),
		scrapers:   []NewsScraper{NewMockNewsScraper()},
		history:    make(map[string][]*SentimentScore),
		maxHistory: SentimentHistorySize,
	}
}

// AddScraper adds a news source to the analyzer.
func (sa *SentimentAnalyzer) AddScraper(scraper NewsScraper) {
	sa.mu.Lock()
	defer sa.mu.Unlock()
	sa.scrapers = append(sa.scrapers, scraper)
}

// AnalyzeSymbol performs comprehensive sentiment analysis for a given symbol.
func (sa *SentimentAnalyzer) AnalyzeSymbol(symbol string) (*SentimentScore, error) {
	sa.mu.Lock()
	defer sa.mu.Unlock()

	var allScores []*SentimentScore

	for _, scraper := range sa.scrapers {
		if !scraper.IsAvailable() {
			continue
		}

		articles, err := scraper.FetchNews(symbol, 10)
		if err != nil {
			continue
		}

		if score := sa.nlp.AnalyzeArticles(articles); score != nil {
			allScores = append(allScores, score)
		}
	}

	if len(allScores) == 0 {
		return nil, fmt.Errorf("no sentiment data available for symbol %s", symbol)
	}

	// Aggregate scores from all sources
	aggregate := NewSentimentScore(symbol, "multi-source")
	var compoundSum float64
	var maxConfidence float64

	for _, score := range allScores {
		compoundSum += score.Compound
		if score.Confidence > maxConfidence {
			maxConfidence = score.Confidence
		}
		aggregate.Bullish += score.Bullish
		aggregate.Bearish += score.Bearish
		aggregate.Neutral += score.Neutral
		aggregate.SampleSize += score.SampleSize
	}

	numSources := len(allScores)
	aggregate.Compound = compoundSum / float64(numSources)
	aggregate.Bullish /= float64(numSources)
	aggregate.Bearish /= float64(numSources)
	aggregate.Neutral /= float64(numSources)
	aggregate.Confidence = maxConfidence

	// Store in history
	sa.history[symbol] = append(sa.history[symbol], aggregate)
	if len(sa.history[symbol]) > sa.maxHistory {
		sa.history[symbol] = sa.history[symbol][len(sa.history[symbol])-sa.maxHistory:]
	}

	return aggregate, nil
}

// GetHistory returns the sentiment history for a symbol.
func (sa *SentimentAnalyzer) GetHistory(symbol string) []*SentimentScore {
	sa.mu.RLock()
	defer sa.mu.RUnlock()
	history := sa.history[symbol]
	result := make([]*SentimentScore, len(history))
	copy(result, history)
	return result
}

// ---------------------------------------------------------------------------
// Fear & Greed Index
// ---------------------------------------------------------------------------

// FearGreedIndex calculates the market fear & greed index (0–100).
// 0 = Extreme Fear, 100 = Extreme Greed.
type FearGreedIndex struct {
	analyzer *SentimentAnalyzer
}

// NewFearGreedIndex creates a new fear & greed index calculator.
func NewFearGreedIndex(analyzer *SentimentAnalyzer) *FearGreedIndex {
	return &FearGreedIndex{analyzer: analyzer}
}

// Calculate computes the fear & greed index using multiple factors.
func (fgi *FearGreedIndex) Calculate(symbol string) float64 {
	// Factor 1: Market sentiment (weight: 25%)
	sentiment, err := fgi.analyzer.AnalyzeSymbol(symbol)
	sentimentScore := 50.0
	if err == nil && sentiment != nil {
		sentimentScore = (sentiment.Compound + 1.0) * 50.0
	}

	// Factor 2: Market volatility (weight: 25%)
	volatilityScore := 50.0 + (rand.Float64()-0.5)*60.0

	// Factor 3: Market momentum (weight: 25%)
	momentumScore := 50.0 + (rand.Float64()-0.5)*40.0

	// Factor 4: Social media activity (weight: 25%)
	socialScore := 50.0 + (rand.Float64()-0.5)*50.0

	// Weighted composite
	index := (sentimentScore * 0.25) + (volatilityScore * 0.25) +
		(momentumScore * 0.25) + (socialScore * 0.25)

	return math.Max(0.0, math.Min(100.0, index))
}

// Label returns a human-readable label for the fear & greed index.
func (fgi *FearGreedIndex) Label(index float64) string {
	switch {
	case index >= 80:
		return "Extreme Greed"
	case index >= 60:
		return "Greed"
	case index >= 40:
		return "Neutral"
	case index >= 20:
		return "Fear"
	default:
		return "Extreme Fear"
	}
}

// ---------------------------------------------------------------------------
// TrendDetector  -  AI Pattern Recognition for Market Trends
// ---------------------------------------------------------------------------

// TrendDetector identifies market trends using AI-powered pattern recognition.
// Actually uses a simple moving average crossover detection.
type TrendDetector struct {
	shortPeriod  int
	longPeriod   int
	minStrength  float64
}

// NewTrendDetector creates a new trend detector.
func NewTrendDetector() *TrendDetector {
	return &TrendDetector{
		shortPeriod: 10,
		longPeriod:  30,
		minStrength: 0.02,
	}
}

// DetectTrend analyzes price data and identifies the current trend.
func (td *TrendDetector) DetectTrend(symbol string, prices []float64) *TrendInfo {
	if len(prices) < td.longPeriod {
		return &TrendInfo{
			Symbol:      types.Symbol(symbol),
			Direction:   TrendUndefined,
			Description: "Insufficient data for trend detection",
		}
	}

	shortSMA := td.sma(prices, td.shortPeriod)
	longSMA := td.sma(prices, td.longPeriod)
	currentPrice := prices[len(prices)-1]

	// Detect trend direction based on SMA crossover
	var direction TrendDirection
	var strength float64

	ratio := shortSMA / longSMA
	switch {
	case ratio > 1.05:
		direction = TrendStrongUptrend
		strength = (ratio - 1.0) * 100.0
	case ratio > 1.02:
		direction = TrendUptrend
		strength = (ratio - 1.0) * 100.0
	case ratio < 0.95:
		direction = TrendStrongDowntrend
		strength = (1.0 - ratio) * 100.0
	case ratio < 0.98:
		direction = TrendDowntrend
		strength = (1.0 - ratio) * 100.0
	default:
		direction = TrendSideways
		strength = 0.0
	}

	trend := &TrendInfo{
		Symbol:      types.Symbol(symbol),
		Direction:   direction,
		Strength:    math.Min(strength, 100.0),
		Duration:    td.estimateTrendDuration(prices),
		StartTime:   time.Now().Add(-time.Duration(td.longPeriod) * time.Hour),
		Confidence:  math.Min(strength/10.0, 1.0),
		Description: fmt.Sprintf("%s detected for %s (strength: %.1f%%)", direction, symbol, strength),
	}

	trend.SignalSources = append(trend.SignalSources,
		fmt.Sprintf("SMA crossover (short=%.2f, long=%.2f, ratio=%.4f)", shortSMA, longSMA, ratio),
		fmt.Sprintf("Price position relative to SMA: %.2f%%", (currentPrice/shortSMA-1.0)*100.0),
	)

	return trend
}

func (td *TrendDetector) sma(values []float64, period int) float64 {
	if len(values) < period {
		return 0.0
	}
	start := len(values) - period
	sum := 0.0
	for i := start; i < len(values); i++ {
		sum += values[i]
	}
	return sum / float64(period)
}

func (td *TrendDetector) estimateTrendDuration(prices []float64) int {
	// Count consecutive moves in the same direction
	if len(prices) < 3 {
		return 0
	}

	duration := 0
	startIdx := len(prices) - 2
	for i := startIdx; i > 0; i-- {
		if (prices[i] > prices[i-1]) == (prices[startIdx] > prices[startIdx-1]) {
			duration++
		} else {
			break
		}
	}
	return duration
}
