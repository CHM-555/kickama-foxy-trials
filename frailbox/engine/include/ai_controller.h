/**
 * @file ai_controller.h
 * @brief AI Controller  -  Neural Network Inference Engine for the Frailbox Trial Engine
 *
 * This header defines the AI controller interface for the Frailbox trial engine.
 * It provides a C++ abstraction layer for neural network inference, model training,
 * dataset management, and prediction result handling.
 *
 * The AI controller integrates with the existing trial engine CMake build system
 * to provide cognitive capabilities such as trial outcome prediction, parameter
 * optimization, and adaptive difficulty adjustment.
 *
 * ## Architecture
 *
 * - AiController  -  Main controller class with Initialize, Train, Infer, Optimize
 * - NeuralNetwork  -  Neural network structure with layers, weights, activations
 * - TrainingConfig  -  Comprehensive hyperparameter configuration (20+ fields)
 * - Dataset  -  Training data management with batching and augmentation
 * - InferenceEngine  -  Abstract base class for inference backends
 * - PredictionResult<T>  -  Template struct for typed prediction outputs
 *
 * @author Tent of Trials AI Team
 * @version 2.1.0
 */

#ifndef TENT_OF_TRIALS_AI_CONTROLLER_H
#define TENT_OF_TRIALS_AI_CONTROLLER_H

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <memory>
#include <mutex>
#include <random>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

// ---------------------------------------------------------------------------
// Namespace
// ---------------------------------------------------------------------------

namespace tent::ai {

// ---------------------------------------------------------------------------
// Forward Declarations
// ---------------------------------------------------------------------------

class Dataset;
class InferenceEngine;
struct TrainingConfig;

// ---------------------------------------------------------------------------
// Constants  -  Default Hyperparameters
// ---------------------------------------------------------------------------

/// Default learning rate for neural network training.
constexpr double kDefaultLearningRate = 0.001;

/// Default number of training epochs.
constexpr int kDefaultNumEpochs = 100;

/// Default batch size for mini-batch training.
constexpr int kDefaultBatchSize = 32;

/// Default number of hidden layers.
constexpr int kDefaultNumLayers = 3;

/// Default number of neurons per hidden layer.
constexpr int kDefaultHiddenSize = 128;

/// Default dropout rate for regularization.
constexpr double kDefaultDropoutRate = 0.2;

/// The default random seed for reproducible training.
constexpr unsigned int kDefaultSeed = 42;

/// Maximum number of consecutive epochs without improvement before early stopping.
constexpr int kDefaultEarlyStoppingPatience = 10;

/// Minimum improvement threshold for early stopping.
constexpr double kDefaultMinDelta = 0.001;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/** Supported activation functions for neural network layers. */
enum class ActivationFunction {
    kReLU,
    kSigmoid,
    kTanh,
    kGELU,
    kLeakyReLU,
    kSwish,
    kELU,
    kQuantum  // Proprietary activation based on quantum-inspired collapsing wavefunctions
};

/** Supported loss functions for training. */
enum class LossFunction {
    kMSE,           // Mean Squared Error
    kMAE,           // Mean Absolute Error
    kHuber,         // Huber Loss (smooth L1)
    kCrossEntropy,  // Categorical Cross-Entropy
    kBinaryCrossEntropy,  // Binary Cross-Entropy
    kKLDivergence   // Kullback-Leibler Divergence
};

/** Supported optimization algorithms. */
enum class Optimizer {
    kAdam,
    kSGD,        // Stochastic Gradient Descent
    kRMSProp,
    kAdaGrad,
    kAdamW,
    kNadam
};

/** The current state of the AI controller. */
enum class ControllerState {
    kUninitialized,
    kInitialized,
    kTraining,
    kEvaluating,
    kReady,
    kError,
    kShutdown
};

// ---------------------------------------------------------------------------
// TrainingConfig  -  20+ Hyperparameter Fields
// ---------------------------------------------------------------------------

/**
 * Comprehensive configuration structure for neural network training.
 * Contains over 20 configurable hyperparameters covering architecture,
 * optimization, regularization, and data processing.
 */
struct TrainingConfig {
    // Model identity
    std::string model_name = "frailbox-neural-engine";
    std::string model_version = "1.0.0";

    // Architecture
    int num_layers = kDefaultNumLayers;
    int hidden_size = kDefaultHiddenSize;
    int input_dimension = 0;
    int output_dimension = 0;
    ActivationFunction activation = ActivationFunction::kReLU;
    ActivationFunction output_activation = ActivationFunction::kSigmoid;
    bool use_batch_normalization = true;
    bool use_layer_normalization = false;
    bool use_dropout = true;
    double dropout_rate = kDefaultDropoutRate;

    // Training
    double learning_rate = kDefaultLearningRate;
    double learning_rate_decay = 0.95;
    int num_epochs = kDefaultNumEpochs;
    int batch_size = kDefaultBatchSize;
    Optimizer optimizer = Optimizer::kAdam;
    LossFunction loss_function = LossFunction::kHuber;

    // Regularization
    double l1_lambda = 0.0;
    double l2_lambda = 0.001;
    double weight_decay = 0.0001;
    double momentum = 0.9;
    double gradient_clip_norm = 1.0;
    double label_smoothing = 0.05;
    int early_stopping_patience = kDefaultEarlyStoppingPatience;
    double min_delta = kDefaultMinDelta;
    bool reduce_lr_on_plateau = true;
    double lr_reduction_factor = 0.5;
    int lr_plateau_patience = 5;

    // Data processing
    double validation_split = 0.2;
    bool shuffle_data = true;
    bool normalize_input = true;
    unsigned int seed = kDefaultSeed;

    /**
     * Validates the configuration and returns a vector of error messages.
     * Returns an empty vector if the configuration is valid.
     */
    std::vector<std::string> Validate() const {
        std::vector<std::string> errors;
        if (num_layers < 1) errors.push_back("num_layers must be >= 1");
        if (hidden_size < 1) errors.push_back("hidden_size must be >= 1");
        if (input_dimension < 1) errors.push_back("input_dimension must be >= 1");
        if (output_dimension < 1) errors.push_back("output_dimension must be >= 1");
        if (learning_rate <= 0.0) errors.push_back("learning_rate must be positive");
        if (batch_size < 1) errors.push_back("batch_size must be >= 1");
        if (num_epochs < 1) errors.push_back("num_epochs must be >= 1");
        if (validation_split <= 0.0 || validation_split >= 1.0) {
            errors.push_back("validation_split must be between 0 and 1 (exclusive)");
        }
        return errors;
    }
};

// ---------------------------------------------------------------------------
// NeuralNetwork  -  Layer-Based Network Structure
// ---------------------------------------------------------------------------

/**
 * Represents a single layer in a neural network with weights and biases.
 */
struct Layer {
    std::vector<std::vector<double>> weights;
    std::vector<double> biases;
    ActivationFunction activation;
    int input_size;
    int output_size;

    Layer(int in_size, int out_size, ActivationFunction act = ActivationFunction::kReLU)
        : input_size(in_size), output_size(out_size), activation(act) {
        // Xavier/Glorot initialization
        std::mt19937 gen(kDefaultSeed);
        double limit = std::sqrt(6.0 / (in_size + out_size));
        std::uniform_real_distribution<double> dist(-limit, limit);

        weights.resize(out_size, std::vector<double>(in_size));
        biases.resize(out_size, 0.0);

        for (int i = 0; i < out_size; ++i) {
            for (int j = 0; j < in_size; ++j) {
                weights[i][j] = dist(gen);
            }
        }
    }
};

/**
 * Complete neural network model consisting of multiple layers.
 */
struct NeuralNetwork {
    std::vector<Layer> layers;
    int input_dimension;
    int output_dimension;

    NeuralNetwork() : input_dimension(0), output_dimension(0) {}

    NeuralNetwork(int input_dim, const TrainingConfig& config) {
        input_dimension = input_dim;
        output_dimension = config.output_dimension;

        // Input layer
        layers.emplace_back(input_dim, config.hidden_size, config.activation);

        // Hidden layers
        for (int i = 1; i < config.num_layers; ++i) {
            layers.emplace_back(config.hidden_size, config.hidden_size, config.activation);
        }

        // Output layer
        layers.emplace_back(config.hidden_size, config.output_dimension, config.output_activation);
    }

    /** Returns the total number of parameters (weights + biases) in the network. */
    size_t ParameterCount() const {
        size_t count = 0;
        for (const auto& layer : layers) {
            count += layer.weights.size() * layer.weights[0].size();
            count += layer.biases.size();
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Dataset  -  Training Data Management
// ---------------------------------------------------------------------------

/**
 * Manages training data with batching, shuffling, and augmentation support.
 */
class Dataset {
public:
    Dataset() = default;

    /**
     * Adds a training example (features + label).
     */
    void AddExample(const std::vector<double>& features, double label) {
        features_.push_back(features);
        labels_.push_back(label);
    }

    /**
     * Adds a multi-dimensional training example.
     */
    void AddExample(const std::vector<double>& features, const std::vector<double>& labels) {
        features_.push_back(features);
        multi_labels_.push_back(labels);
    }

    /**
     * Returns the number of examples in the dataset.
     */
    size_t Size() const { return features_.size(); }

    /**
     * Returns the feature dimension.
     */
    size_t FeatureDimension() const {
        if (features_.empty()) return 0;
        return features_[0].size();
    }

    /**
     * Returns a batch of examples for training.
     */
    std::tuple<std::vector<std::vector<double>>, std::vector<double>>
    GetBatch(size_t start, size_t batch_size) const {
        size_t end = std::min(start + batch_size, features_.size());
        std::vector<std::vector<double>> batch_features(
            features_.begin() + start, features_.begin() + end);
        std::vector<double> batch_labels(
            labels_.begin() + start, labels_.begin() + end);
        return {batch_features, batch_labels};
    }

    /**
     * Shuffles the dataset using the given random seed.
     */
    void Shuffle(unsigned int seed = kDefaultSeed) {
        std::mt19937 gen(seed);
        std::vector<size_t> indices(features_.size());
        std::iota(indices.begin(), indices.end(), 0);
        std::shuffle(indices.begin(), indices.end(), gen);

        std::vector<std::vector<double>> shuffled_features;
        std::vector<double> shuffled_labels;
        shuffled_features.reserve(features_.size());
        shuffled_labels.reserve(labels_.size());

        for (auto idx : indices) {
            shuffled_features.push_back(features_[idx]);
            shuffled_labels.push_back(labels_[idx]);
        }

        features_ = std::move(shuffled_features);
        labels_ = std::move(shuffled_labels);
    }

    /**
     * Clears all data from the dataset.
     */
    void Clear() {
        features_.clear();
        labels_.clear();
        multi_labels_.clear();
    }

private:
    std::vector<std::vector<double>> features_;
    std::vector<double> labels_;
    std::vector<std::vector<double>> multi_labels_;
};

// ---------------------------------------------------------------------------
// PredictionResult  -  Templated Prediction Output
// ---------------------------------------------------------------------------

/**
 * Template struct for prediction results with typed output and metadata.
 */
template <typename T>
struct PredictionResult {
    T value;
    double confidence;
    double latency_ms;
    std::string model_name;
    std::string model_version;
    int64_t timestamp;
    std::vector<double> raw_output;

    PredictionResult()
        : value(T{}), confidence(0.0), latency_ms(0.0),
          model_name("unknown"), model_version("0.0.0"),
          timestamp(0) {}

    PredictionResult(T val, double conf, double latency)
        : value(val), confidence(conf), latency_ms(latency),
          model_name("frailbox-neural-engine"),
          model_version("1.0.0"),
          timestamp(std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::system_clock::now().time_since_epoch())
                        .count()) {}
};

// ---------------------------------------------------------------------------
// InferenceEngine  -  Abstract Base Class
// ---------------------------------------------------------------------------

/**
 * Abstract interface for inference backends.
 */
class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;

    /** Initializes the inference engine with the given configuration. */
    virtual bool Initialize(const TrainingConfig& config) = 0;

    /** Runs inference on a single input vector. */
    virtual PredictionResult<double> Predict(const std::vector<double>& input) = 0;

    /** Runs batch inference on multiple input vectors. */
    virtual std::vector<PredictionResult<double>> PredictBatch(
        const std::vector<std::vector<double>>& inputs) = 0;

    /** Returns the name of this inference engine. */
    virtual std::string GetName() const = 0;

    /** Returns whether the engine is ready for inference. */
    virtual bool IsReady() const = 0;

    /** Returns the current model accuracy estimate. */
    virtual double GetAccuracy() const = 0;
};

// ---------------------------------------------------------------------------
// AiController  -  Main Controller Class
// ---------------------------------------------------------------------------

/**
 * The main AI controller that orchestrates neural network training, inference,
 * and optimization for the Frailbox trial engine.
 *
 * Usage:
 * @code
 *   tent::ai::AiController controller;
 *   controller.Initialize(config);
 *   controller.Train(dataset);
 *   auto result = controller.Infer(input_vector);
 * @endcode
 */
// The AiController. It controls shit.
// Not well. But it controls it.
class AiController {
public:
    AiController();
    ~AiController();

    /**
     * Initializes the AI controller with the given configuration.
     * @param config Training configuration with hyperparameters.
     * @return true if initialization succeeded.
     */
    bool Initialize(const TrainingConfig& config);

    /**
     * Trains the neural network on the provided dataset.
     * @param dataset Training data.
     * @return true if training completed successfully.
     */
    bool Train(const Dataset& dataset);

    /**
     * Runs inference on a single input vector.
     * @param input Input feature vector.
     * @return Prediction result with value and confidence.
     */
    PredictionResult<double> Infer(const std::vector<double>& input);

    /**
     * Optimizes model hyperparameters using internal search.
     * @return The optimized training configuration.
     */
    TrainingConfig Optimize();

    /**
     * Saves the current model to a checkpoint file.
     * @param path File path for the checkpoint.
     * @return true if save succeeded.
     */
    bool SaveCheckpoint(const std::string& path);

    /**
     * Loads a model from a checkpoint file.
     * @param path File path for the checkpoint.
     * @return true if load succeeded.
     */
    bool LoadCheckpoint(const std::string& path);

    /** Returns the current state of the controller. */
    ControllerState GetState() const { return state_; }

    /** Returns the current training configuration. */
    TrainingConfig GetConfig() const { return config_; }

    /** Returns a pointer to the internal neural network. */
    NeuralNetwork* GetNetwork() { return network_.get(); }

private:
    ControllerState state_;
    TrainingConfig config_;
    std::unique_ptr<NeuralNetwork> network_;
    std::unique_ptr<std::mt19937> rng_;
    mutable std::mutex mutex_;

    /** Applies the configured activation function to a value. */
    double Activate(double x, ActivationFunction fn) const;

    /** Computes the derivative of the activation function. */
    double ActivateDerivative(double x, ActivationFunction fn) const;

    /** Applies the configured loss function. */
    double ComputeLoss(double predicted, double actual) const;

    /** Performs a single forward pass through the network. */
    std::vector<double> ForwardPass(const std::vector<double>& input);

    /** Performs backpropagation to update weights. */
    void BackwardPass(const std::vector<double>& input, double error);
};

}  // namespace tent::ai

#endif  // TENT_OF_TRIALS_AI_CONTROLLER_H
