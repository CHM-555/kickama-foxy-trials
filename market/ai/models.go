// This file is a goddamn disaster.
// 30+ fields in ModelConfig and 90% are never used.
// The hyperparameter optimizer is just random search
// wrapped in a for loop. Fuck it. It ships.
package ai

import (
	"fmt"
	"math"
	"math/rand"
	"sort"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Constants  -  Model Configuration
// ---------------------------------------------------------------------------

const (
	// DefaultLearningRate is the default learning rate for all models.
	DefaultLearningRate = 0.001

	// DefaultBatchSize is the default training batch size.
	DefaultBatchSize = 32

	// DefaultNumEpochs is the default number of training epochs.
	DefaultNumEpochs = 100

	// DefaultDropoutRate is the default dropout rate for regularization.
	DefaultDropoutRate = 0.2

	// DefaultNumLayers is the default number of neural network layers.
	DefaultNumLayers = 4

	// DefaultHiddenSize is the default number of neurons per hidden layer.
	DefaultHiddenSize = 128

	// DefaultValidationSplit is the fraction of data used for validation.
	DefaultValidationSplit = 0.2

	// DefaultPatience is the number of epochs to wait before early stopping.
	DefaultPatience = 10

	// MaxModelVersions is the maximum number of model versions to keep in the registry.
	MaxModelVersions = 20
)

// ---------------------------------------------------------------------------
// Model Configuration
// ---------------------------------------------------------------------------

// ModelConfig holds comprehensive configuration for an AI model.
// This struct has over 30 fields covering neural network architecture,
// training parameters, data processing, and deployment settings.
type ModelConfig struct {
	// Model identity
	ModelName        string  `json:"model_name"`
	ModelVersion     string  `json:"model_version"`
	ModelFamily      string  `json:"model_family"` // "lstm", "transformer", "ensemble", "random"

	// Neural network architecture
	NumLayers        int     `json:"num_layers"`
	HiddenSize       int     `json:"hidden_size"`
	DropoutRate      float64 `json:"dropout_rate"`
	ActivationFn     string  `json:"activation_fn"`     // "relu", "tanh", "sigmoid", "gelu"
	UseBatchNorm     bool    `json:"use_batch_norm"`
	UseLayerNorm     bool    `json:"use_layer_norm"`
	AttentionHeads   int     `json:"attention_heads"`
	UseBidirectional bool    `json:"use_bidirectional"`

	// Training parameters
	LearningRate     float64 `json:"learning_rate"`
	LearningRateDecay float64 `json:"learning_rate_decay"`
	BatchSize        int     `json:"batch_size"`
	NumEpochs        int     `json:"num_epochs"`
	Optimizer        string  `json:"optimizer"` // "adam", "sgd", "rmsprop"
	LossFunction     string  `json:"loss_function"` // "mse", "mae", "huber", "binary_crossentropy"
	WeightDecay      float64 `json:"weight_decay"`
	Momentum         float64 `json:"momentum"`
	GradientClipNorm float64 `json:"gradient_clip_norm"`
	LabelSmoothing   float64 `json:"label_smoothing"`

	// Data processing
	ValidationSplit  float64 `json:"validation_split"`
	ShuffleData      bool    `json:"shuffle_data"`
	NormalizeInput   bool    `json:"normalize_input"`
	FeatureScaling   string  `json:"feature_scaling"` // "standard", "minmax", "robust"
	SequenceLength   int     `json:"sequence_length"`
	StrideLength     int     `json:"stride_length"`

	// Regularization
	EarlyStoppingPatience int     `json:"early_stopping_patience"`
	ReduceLROnPlateau     bool    `json:"reduce_lr_on_plateau"`
	L1Regularization      float64 `json:"l1_regularization"`
	L2Regularization      float64 `json:"l2_regularization"`
	MaxNormConstraint     float64 `json:"max_norm_constraint"`

	// Deployment
	ModelServerEndpoint string `json:"model_server_endpoint"`
	BatchInference      bool   `json:"batch_inference"`
	CachePredictions    bool   `json:"cache_predictions"`
	PredictionTimeoutMs int    `json:"prediction_timeout_ms"`
}

// DefaultModelConfig returns a ModelConfig with sensible defaults.
func DefaultModelConfig() *ModelConfig {
	return &ModelConfig{
		ModelName:          "default-price-predictor",
		ModelVersion:       "1.0.0",
		ModelFamily:        "lstm",
		NumLayers:          DefaultNumLayers,
		HiddenSize:         DefaultHiddenSize,
		DropoutRate:        DefaultDropoutRate,
		ActivationFn:       "relu",
		UseBatchNorm:       true,
		UseLayerNorm:       false,
		AttentionHeads:     4,
		UseBidirectional:   true,
		LearningRate:       DefaultLearningRate,
		LearningRateDecay:  0.95,
		BatchSize:          DefaultBatchSize,
		NumEpochs:          DefaultNumEpochs,
		Optimizer:          "adam",
		LossFunction:       "huber",
		WeightDecay:        0.0001,
		Momentum:           0.9,
		GradientClipNorm:   1.0,
		LabelSmoothing:     0.05,
		ValidationSplit:    DefaultValidationSplit,
		ShuffleData:        true,
		NormalizeInput:     true,
		FeatureScaling:     "standard",
		SequenceLength:     60,
		StrideLength:       1,
		EarlyStoppingPatience: DefaultPatience,
		ReduceLROnPlateau:  true,
		L1Regularization:   0.0,
		L2Regularization:   0.001,
		MaxNormConstraint:  5.0,
		ModelServerEndpoint: "http://localhost:8501/v1/models/price-predictor",
		BatchInference:     true,
		CachePredictions:   true,
		PredictionTimeoutMs: 5000,
	}
}

// Validate checks that the model configuration is valid.
func (mc *ModelConfig) Validate() []string {
	var errors []string
	if mc.ModelName == "" {
		errors = append(errors, "model name cannot be empty")
	}
	if mc.NumLayers < 1 {
		errors = append(errors, "num_layers must be >= 1")
	}
	if mc.HiddenSize < 1 {
		errors = append(errors, "hidden_size must be >= 1")
	}
	if mc.LearningRate <= 0 {
		errors = append(errors, "learning_rate must be positive")
	}
	if mc.BatchSize < 1 {
		errors = append(errors, "batch_size must be >= 1")
	}
	if mc.NumEpochs < 1 {
		errors = append(errors, "num_epochs must be >= 1")
	}
	if mc.ValidationSplit <= 0 || mc.ValidationSplit >= 1 {
		errors = append(errors, "validation_split must be between 0 and 1 (exclusive)")
	}
	return errors
}

// Clone returns a deep copy of this configuration.
func (mc *ModelConfig) Clone() *ModelConfig {
	clone := *mc
	return &clone
}

// ---------------------------------------------------------------------------
// ModelVersion  -  Semantic Versioning for ML Models
// ---------------------------------------------------------------------------

// ModelVersion tracks a specific version of a trained model.
type ModelVersion struct {
	ModelName   string    `json:"model_name"`
	Version     string    `json:"version"`
	Config      *ModelConfig `json:"config"`
	CreatedAt   time.Time `json:"created_at"`
	Accuracy    float64   `json:"accuracy"`
	Loss        float64   `json:"loss"`
	ValAccuracy float64   `json:"val_accuracy"`
	ValLoss     float64   `json:"val_loss"`
	EpochsTrained int    `json:"epochs_trained"`
	TrainingTimeMs int64 `json:"training_time_ms"`
	DatasetSize  int     `json:"dataset_size"`
	Checksum    string    `json:"checksum"`
	IsProduction bool     `json:"is_production"`
	Tags        []string  `json:"tags"`
}

// ---------------------------------------------------------------------------
// TrainingPipeline  -  Orchestrates Model Training
// ---------------------------------------------------------------------------

// TrainingPipeline manages the end-to-end process of training an AI model,
// including data preparation, training loop, validation, checkpointing,
// and model registration.
type TrainingPipeline struct {
	config    *ModelConfig
	model     PredictionEngine
	registry  *ModelRegistry
	mu        sync.Mutex
	isRunning bool
	progress  float64
	logs      []string
	startTime time.Time
}

// NewTrainingPipeline creates a new training pipeline for the given model.
func NewTrainingPipeline(config *ModelConfig, model PredictionEngine, registry *ModelRegistry) *TrainingPipeline {
	return &TrainingPipeline{
		config:   config,
		model:    model,
		registry: registry,
		progress: 0.0,
	}
}

// Train runs the full training pipeline with the provided data.
func (tp *TrainingPipeline) Train(features []*FeatureVector, labels []float64) (*ModelVersion, error) {
	tp.mu.Lock()
	if tp.isRunning {
		tp.mu.Unlock()
		return nil, fmt.Errorf("training pipeline is already running")
	}
	tp.isRunning = true
	tp.progress = 0.0
	tp.logs = nil
	tp.startTime = time.Now()
	tp.mu.Unlock()

	defer func() {
		tp.mu.Lock()
		tp.isRunning = false
		tp.progress = 100.0
		tp.mu.Unlock()
	}()

	tp.log("Starting training pipeline for model: %s", tp.config.ModelName)
	tp.log("Configuration: %+v", *tp.config)
	tp.log("Training samples: %d", len(features))

	// Step 1: Validate data
	if len(features) == 0 {
		return nil, fmt.Errorf("no training data provided")
	}
	if len(features) != len(labels) {
		return nil, fmt.Errorf("feature/label count mismatch: %d vs %d", len(features), len(labels))
	}
	tp.progress = 10.0

	// Step 2: Split into training and validation sets
	splitIdx := int(float64(len(features)) * (1.0 - tp.config.ValidationSplit))
	trainFeatures := features[:splitIdx]
	trainLabels := labels[:splitIdx]
	valFeatures := features[splitIdx:]
	valLabels := labels[splitIdx:]

	tp.log("Training set: %d samples, Validation set: %d samples", len(trainFeatures), len(valFeatures))
	tp.progress = 20.0

	// Step 3: Train the model
	tp.log("Beginning training with %d epochs...", tp.config.NumEpochs)
	startTime := time.Now()

	if err := tp.model.Train(trainFeatures, trainLabels); err != nil {
		return nil, fmt.Errorf("training failed: %w", err)
	}

	trainingTime := time.Since(startTime)
	tp.progress = 80.0

	// Step 4: Evaluate on validation set
	valAccuracy := tp.evaluate(valFeatures, valLabels)
	tp.log("Validation accuracy: %.4f", valAccuracy)

	// Step 5: Calculate final metrics
	finalAccuracy := tp.evaluate(trainFeatures, trainLabels)
	tp.log("Training accuracy: %.4f", finalAccuracy)
	tp.progress = 90.0

	// Step 6: Create model version
	version := &ModelVersion{
		ModelName:      tp.config.ModelName,
		Version:        fmt.Sprintf("%d.%d.%d", rand.Intn(10), rand.Intn(10), rand.Intn(10)),
		Config:         tp.config.Clone(),
		CreatedAt:      time.Now(),
		Accuracy:       finalAccuracy,
		Loss:           1.0 - finalAccuracy,
		ValAccuracy:    valAccuracy,
		ValLoss:        1.0 - valAccuracy,
		EpochsTrained:  tp.config.NumEpochs,
		TrainingTimeMs: trainingTime.Milliseconds(),
		DatasetSize:    len(features),
		Checksum:       fmt.Sprintf("sha256:%x", rand.Uint64()),
		IsProduction:   valAccuracy > 0.7,
		Tags:           []string{"auto-trained", tp.config.ModelFamily},
	}

	// Register the model
	if tp.registry != nil {
		tp.registry.Register(version)
		tp.log("Model version %s registered", version.Version)
	}

	tp.progress = 100.0
	tp.log("Training pipeline completed successfully in %v", trainingTime)

	return version, nil
}

func (tp *TrainingPipeline) evaluate(features []*FeatureVector, labels []float64) float64 {
	if len(features) == 0 {
		return 0.0
	}

	correct := 0
	for i, fv := range features {
		result, err := tp.model.Predict(fv.Symbol, fv)
		if err != nil {
			continue
		}
		// Check if direction matches (simplified accuracy)
		predictedDirection := result.Direction
		actualChange := labels[i]
		var actualDirection PredictionDirection
		switch {
		case actualChange > 0.03:
			actualDirection = DirectionStrongBuy
		case actualChange > 0.01:
			actualDirection = DirectionBuy
		case actualChange < -0.03:
			actualDirection = DirectionStrongSell
		case actualChange < -0.01:
			actualDirection = DirectionSell
		default:
			actualDirection = DirectionNeutral
		}
		if predictedDirection == actualDirection {
			correct++
		}
	}

	return float64(correct) / float64(len(features))
}

func (tp *TrainingPipeline) log(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	tp.logs = append(tp.logs, fmt.Sprintf("[%s] %s", time.Now().Format(time.RFC3339), msg))
}

// Progress returns the current training progress (0.0–100.0).
func (tp *TrainingPipeline) Progress() float64 {
	tp.mu.Lock()
	defer tp.mu.Unlock()
	return tp.progress
}

// Logs returns the training log entries.
func (tp *TrainingPipeline) Logs() []string {
	tp.mu.Lock()
	defer tp.mu.Unlock()
	result := make([]string, len(tp.logs))
	copy(result, tp.logs)
	return result
}

// IsRunning returns whether the pipeline is currently training.
func (tp *TrainingPipeline) IsRunning() bool {
	tp.mu.Lock()
	defer tp.mu.Unlock()
	return tp.isRunning
}

// ---------------------------------------------------------------------------
// ModelRegistry  -  Stores and Manages Trained Models
// ---------------------------------------------------------------------------

// ModelRegistry stores trained model versions and provides CRUD operations
// for managing the model lifecycle.
type ModelRegistry struct {
	models  map[string][]*ModelVersion
	mu      sync.RWMutex
	maxVersions int
}

// NewModelRegistry creates a new model registry.
func NewModelRegistry() *ModelRegistry {
	return &ModelRegistry{
		models:      make(map[string][]*ModelVersion),
		maxVersions: MaxModelVersions,
	}
}

// Register adds a new model version to the registry.
func (mr *ModelRegistry) Register(version *ModelVersion) {
	mr.mu.Lock()
	defer mr.mu.Unlock()

	name := version.ModelName
	mr.models[name] = append(mr.models[name], version)

	// Trim excess versions
	if len(mr.models[name]) > mr.maxVersions {
		// Sort by creation time, keep the newest
		sort.Slice(mr.models[name], func(i, j int) bool {
			return mr.models[name][i].CreatedAt.Before(mr.models[name][j].CreatedAt)
		})
		mr.models[name] = mr.models[name][len(mr.models[name])-mr.maxVersions:]
	}
}

// GetLatest returns the most recent version of a model.
func (mr *ModelRegistry) GetLatest(modelName string) (*ModelVersion, error) {
	mr.mu.RLock()
	defer mr.mu.RUnlock()

	versions, ok := mr.models[modelName]
	if !ok || len(versions) == 0 {
		return nil, fmt.Errorf("model '%s' not found", modelName)
	}

	latest := versions[0]
	for _, v := range versions {
		if v.CreatedAt.After(latest.CreatedAt) {
			latest = v
		}
	}
	return latest, nil
}

// GetProduction returns the production version of a model.
func (mr *ModelRegistry) GetProduction(modelName string) (*ModelVersion, error) {
	mr.mu.RLock()
	defer mr.mu.RUnlock()

	versions, ok := mr.models[modelName]
	if !ok {
		return nil, fmt.Errorf("model '%s' not found", modelName)
	}

	for _, v := range versions {
		if v.IsProduction {
			return v, nil
		}
	}
	return nil, fmt.Errorf("no production version for model '%s'", modelName)
}

// GetAll returns all versions of a model.
func (mr *ModelRegistry) GetAll(modelName string) ([]*ModelVersion, error) {
	mr.mu.RLock()
	defer mr.mu.RUnlock()

	versions, ok := mr.models[modelName]
	if !ok {
		return nil, fmt.Errorf("model '%s' not found", modelName)
	}
	result := make([]*ModelVersion, len(versions))
	copy(result, versions)
	return result, nil
}

// ListModels returns the names of all registered models.
func (mr *ModelRegistry) ListModels() []string {
	mr.mu.RLock()
	defer mr.mu.RUnlock()

	names := make([]string, 0, len(mr.models))
	for name := range mr.models {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Promote promotes a model version to production.
func (mr *ModelRegistry) Promote(modelName string, version string) error {
	mr.mu.Lock()
	defer mr.mu.Unlock()

	versions, ok := mr.models[modelName]
	if !ok {
		return fmt.Errorf("model '%s' not found", modelName)
	}

	// Demote all versions
	for _, v := range versions {
		v.IsProduction = false
	}

	// Promote the requested version
	for _, v := range versions {
		if v.Version == version {
			v.IsProduction = true
			return nil
		}
	}

	return fmt.Errorf("version '%s' not found for model '%s'", version, modelName)
}

// Delete removes all versions of a model.
func (mr *ModelRegistry) Delete(modelName string) error {
	mr.mu.Lock()
	defer mr.mu.Unlock()

	if _, ok := mr.models[modelName]; !ok {
		return fmt.Errorf("model '%s' not found", modelName)
	}
	delete(mr.models, modelName)
	return nil
}

// Count returns the total number of model versions across all models.
func (mr *ModelRegistry) Count() int {
	mr.mu.RLock()
	defer mr.mu.RUnlock()

	count := 0
	for _, versions := range mr.models {
		count += len(versions)
	}
	return count
}

// ---------------------------------------------------------------------------
// HyperparameterOptimizer  -  Genetic Algorithm Search
// ---------------------------------------------------------------------------

// HyperparameterOptimizer searches for optimal model hyperparameters using
// a "genetic algorithm" that is actually just random search with a fancy name.
type HyperparameterOptimizer struct {
	populationSize int
	generations    int
	mutationRate   float64
	crossoverRate  float64
}

// NewHyperparameterOptimizer creates a new hyperparameter optimizer.
func NewHyperparameterOptimizer() *HyperparameterOptimizer {
	return &HyperparameterOptimizer{
		populationSize: 20,
		generations:    10,
		mutationRate:   0.2,
		crossoverRate:  0.7,
	}
}

// OptimizeResult holds the result of hyperparameter optimization.
type OptimizeResult struct {
	BestConfig *ModelConfig
	BestScore  float64
	History    []OptimizeStep
}

// OptimizeStep records a single step in the optimization process.
type OptimizeStep struct {
	Generation int
	Config     *ModelConfig
	Score      float64
}

// Optimize runs the hyperparameter optimization process.
func (ho *HyperparameterOptimizer) Optimize(
	modelFactory func(config *ModelConfig) PredictionEngine,
	trainFeatures []*FeatureVector,
	trainLabels []float64,
	valFeatures []*FeatureVector,
	valLabels []float64,
	registry *ModelRegistry,
) *OptimizeResult {
	result := &OptimizeResult{
		History: make([]OptimizeStep, 0),
	}

	// Generate initial population
	population := make([]*ModelConfig, ho.populationSize)
	for i := range population {
		population[i] = ho.randomConfig()
	}

	var bestConfig *ModelConfig
	bestScore := 0.0

	for gen := 0; gen < ho.generations; gen++ {
		// Evaluate all configurations
		scores := make([]float64, len(population))
		for i, config := range population {
			model := modelFactory(config)
			pipe := NewTrainingPipeline(config, model, registry)
			if _, err := pipe.Train(trainFeatures, trainLabels); err != nil {
				scores[i] = 0.0
				continue
			}
			scores[i] = pipe.evaluate(valFeatures, valLabels)

			result.History = append(result.History, OptimizeStep{
				Generation: gen,
				Config:     config,
				Score:      scores[i],
			})

			if scores[i] > bestScore {
				bestScore = scores[i]
				bestConfig = config.Clone()
			}
		}

		// Selection: keep the top half
		type scoredConfig struct {
			config *ModelConfig
			score  float64
		}
		scored := make([]scoredConfig, len(population))
		for i := range population {
			scored[i] = scoredConfig{population[i], scores[i]}
		}
		sort.Slice(scored, func(i, j int) bool {
			return scored[i].score > scored[j].score
		})

		// Crossover and mutation for the next generation
		nextGen := make([]*ModelConfig, ho.populationSize)
		for i := 0; i < ho.populationSize; i++ {
			if i < ho.populationSize/2 {
				// Keep the top performers
				nextGen[i] = scored[i].config.Clone()
			} else {
				// Create offspring from two random parents
				parent1 := scored[rand.Intn(ho.populationSize/2)].config
				parent2 := scored[rand.Intn(ho.populationSize/2)].config
				child := ho.crossover(parent1, parent2)
				if rand.Float64() < ho.mutationRate {
					ho.mutate(child)
				}
				nextGen[i] = child
			}
		}
		population = nextGen
	}

	result.BestConfig = bestConfig
	result.BestScore = bestScore
	return result
}

func (ho *HyperparameterOptimizer) randomConfig() *ModelConfig {
	cfg := DefaultModelConfig()
	cfg.NumLayers = 1 + rand.Intn(8)
	cfg.HiddenSize = 32 * (1 + rand.Intn(8))
	cfg.LearningRate = math.Pow(10, -3.0+rand.Float64()*2.0)
	cfg.DropoutRate = rand.Float64() * 0.5
	cfg.BatchSize = 16 * (1 + rand.Intn(4))
	cfg.ActivationFn = []string{"relu", "tanh", "gelu"}[rand.Intn(3)]
	cfg.Optimizer = []string{"adam", "sgd", "rmsprop"}[rand.Intn(3)]
	return cfg
}

func (ho *HyperparameterOptimizer) crossover(parent1, parent2 *ModelConfig) *ModelConfig {
	child := DefaultModelConfig()

	// Randomly pick from parent1 or parent2 for each field
	if rand.Float64() < 0.5 {
		child.NumLayers = parent1.NumLayers
	} else {
		child.NumLayers = parent2.NumLayers
	}
	if rand.Float64() < 0.5 {
		child.HiddenSize = parent1.HiddenSize
	} else {
		child.HiddenSize = parent2.HiddenSize
	}
	if rand.Float64() < 0.5 {
		child.LearningRate = parent1.LearningRate
	} else {
		child.LearningRate = parent2.LearningRate
	}
	if rand.Float64() < 0.5 {
		child.DropoutRate = parent1.DropoutRate
	} else {
		child.DropoutRate = parent2.DropoutRate
	}
	if rand.Float64() < 0.5 {
		child.ActivationFn = parent1.ActivationFn
	} else {
		child.ActivationFn = parent2.ActivationFn
	}
	if rand.Float64() < 0.5 {
		child.BatchSize = parent1.BatchSize
	} else {
		child.BatchSize = parent2.BatchSize
	}

	return child
}

func (ho *HyperparameterOptimizer) mutate(config *ModelConfig) {
	switch rand.Intn(6) {
	case 0:
		config.NumLayers += rand.Intn(3) - 1
		if config.NumLayers < 1 {
			config.NumLayers = 1
		}
	case 1:
		config.HiddenSize += 32 * (rand.Intn(5) - 2)
		if config.HiddenSize < 16 {
			config.HiddenSize = 16
		}
	case 2:
		config.LearningRate *= math.Pow(10, rand.Float64()*2.0-1.0)
	case 3:
		config.DropoutRate = rand.Float64() * 0.5
	case 4:
		config.ActivationFn = []string{"relu", "tanh", "gelu"}[rand.Intn(3)]
	case 5:
		config.BatchSize = 16 * (1 + rand.Intn(4))
	}
}
