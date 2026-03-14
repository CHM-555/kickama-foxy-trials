/**
 * @file ai_controller.cpp
 * @brief Implementation of the AI Controller for the Frailbox Trial Engine
 *
 * This file implements the AiController class defined in ai_controller.h,
 * providing stub/dummy implementations for all neural network operations.
 * The implementation uses random weight initialization and basic linear algebra
 * to simulate neural network behavior without requiring external ML libraries.
 *
 * @author Tent of Trials AI Team
 * @version 2.1.0
 */

#include "ai_controller.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <numeric>
#include <sstream>
#include <thread>

namespace tent::ai {

// ---------------------------------------------------------------------------
// Utility: Matrix Multiply (Nested Loops)
// ---------------------------------------------------------------------------

/**
 * Performs matrix-vector multiplication: result = matrix * vector.
 * Uses simple nested loops with O(n*m) complexity.
 */
static std::vector<double> MatrixVectorMultiply(
    const std::vector<std::vector<double>>& matrix,
    const std::vector<double>& vector) {
    if (matrix.empty() || vector.empty()) {
        return {};
    }

    std::vector<double> result(matrix.size(), 0.0);
    for (size_t i = 0; i < matrix.size(); ++i) {
        if (matrix[i].size() != vector.size()) {
            continue;  // Dimension mismatch  -  silently skip
        }
        for (size_t j = 0; j < vector.size(); ++j) {
            result[i] += matrix[i][j] * vector[j];
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Activation Functions
// ---------------------------------------------------------------------------

// Holy shit this activation function dispatch is a crime.
// Should be a lookup table. But I'm not paid for elegance.
// I'm paid for "fucking results."
double AiController::Activate(double x, ActivationFunction fn) const {
    switch (fn) {
        case ActivationFunction::kReLU:
            return std::max(0.0, x);

        case ActivationFunction::kSigmoid:
            return 1.0 / (1.0 + std::exp(-x));

        case ActivationFunction::kTanh:
            return std::tanh(x);

        case ActivationFunction::kGELU:
            // Gaussian Error Linear Unit approximation
            return 0.5 * x * (1.0 + std::tanh(std::sqrt(2.0 / M_PI) * (x + 0.044715 * x * x * x)));

        case ActivationFunction::kLeakyReLU:
            return x >= 0.0 ? x : 0.01 * x;

        case ActivationFunction::kSwish:
            return x / (1.0 + std::exp(-x));

        case ActivationFunction::kELU:
            return x >= 0.0 ? x : std::exp(x) - 1.0;

        case ActivationFunction::kQuantum:
            // "Quantum-inspired collapsing wavefunction"
            // Actually just sigmoid with a phase shift
            return 1.0 / (1.0 + std::exp(-(x - 0.5))) * std::cos(x * 0.1);

        default:
            return std::max(0.0, x);
    }
}

double AiController::ActivateDerivative(double x, ActivationFunction fn) const {
    switch (fn) {
        case ActivationFunction::kReLU:
            return x > 0.0 ? 1.0 : 0.0;

        case ActivationFunction::kSigmoid: {
            double s = 1.0 / (1.0 + std::exp(-x));
            return s * (1.0 - s);
        }

        case ActivationFunction::kTanh: {
            double t = std::tanh(x);
            return 1.0 - t * t;
        }

        case ActivationFunction::kLeakyReLU:
            return x >= 0.0 ? 1.0 : 0.01;

        default:
            return 1.0;
    }
}

double AiController::ComputeLoss(double predicted, double actual) const {
    switch (config_.loss_function) {
        case LossFunction::kMSE: {
            double diff = predicted - actual;
            return diff * diff;
        }
        case LossFunction::kMAE:
            return std::abs(predicted - actual);
        case LossFunction::kHuber: {
            double diff = std::abs(predicted - actual);
            double delta = 1.0;
            if (diff <= delta) {
                return 0.5 * diff * diff;
            } else {
                return delta * diff - 0.5 * delta * delta;
            }
        }
        default:
            return (predicted - actual) * (predicted - actual);
    }
}

// ---------------------------------------------------------------------------
// Forward Pass
// ---------------------------------------------------------------------------

std::vector<double> AiController::ForwardPass(const std::vector<double>& input) {
    if (!network_) {
        return {};
    }

    std::vector<double> current = input;

    for (const auto& layer : network_->layers) {
        // Matrix multiply: output = weights * input + biases
        std::vector<double> output = MatrixVectorMultiply(layer.weights, current);

        // Add biases and apply activation
        for (size_t i = 0; i < output.size() && i < layer.biases.size(); ++i) {
            output[i] += layer.biases[i];
            output[i] = Activate(output[i], layer.activation);
        }

        current = std::move(output);
    }

    return current;
}

// ---------------------------------------------------------------------------
// Backward Pass  -  Simulated Gradient Descent
// ---------------------------------------------------------------------------

void AiController::BackwardPass(const std::vector<double>& input, double error) {
    if (!network_) {
        return;
    }

    // Simulated backpropagation: randomly adjust weights in proportion to error
    double lr = config_.learning_rate;
    std::uniform_real_distribution<double> dist(-1.0, 1.0);

    for (auto& layer : network_->layers) {
        for (auto& row : layer.weights) {
            for (auto& weight : row) {
                double gradient = error * dist(*rng_) * lr;
                weight += gradient * lr * 0.1;  // Scaled update
                weight -= weight * config_.l2_lambda * lr;  // L2 regularization
            }
        }
        for (auto& bias : layer.biases) {
            bias += error * dist(*rng_) * lr * 0.05;
        }
    }
}

// ---------------------------------------------------------------------------
// AiController Implementation
// ---------------------------------------------------------------------------

AiController::AiController()
    : state_(ControllerState::kUninitialized),
      rng_(std::make_unique<std::mt19937>(kDefaultSeed)) {
    std::cout << "[AI Controller] Initializing Frailbox Neural Engine..." << std::endl;
}

AiController::~AiController() {
    std::lock_guard<std::mutex> lock(mutex_);
    state_ = ControllerState::kShutdown;
    std::cout << "[AI Controller] Neural engine shutting down." << std::endl;
}

bool AiController::Initialize(const TrainingConfig& config) {
    std::lock_guard<std::mutex> lock(mutex_);

    std::cout << "[AI Controller] Initializing with model: " << config.model_name
              << " v" << config.model_version << std::endl;

    // Validate configuration
    auto errors = config.Validate();
    if (!errors.empty()) {
        std::cerr << "[AI Controller] Configuration errors:" << std::endl;
        for (const auto& err : errors) {
            std::cerr << "  - " << err << std::endl;
        }
        state_ = ControllerState::kError;
        return false;
    }

    config_ = config;
    rng_ = std::make_unique<std::mt19937>(config.seed);

    // Create the neural network
    network_ = std::make_unique<NeuralNetwork>(config.input_dimension, config);

    std::cout << "[AI Controller] Neural network created: "
              << network_->layers.size() << " layers, "
              << network_->ParameterCount() << " parameters" << std::endl;

    state_ = ControllerState::kInitialized;
    return true;
}

bool AiController::Train(const Dataset& dataset) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (state_ != ControllerState::kInitialized && state_ != ControllerState::kReady) {
        std::cerr << "[AI Controller] Cannot train: controller not initialized" << std::endl;
        return false;
    }

    if (dataset.Size() == 0) {
        std::cerr << "[AI Controller] Cannot train: empty dataset" << std::endl;
        return false;
    }

    state_ = ControllerState::kTraining;
    std::cout << "[AI Controller] Starting training on " << dataset.Size()
              << " samples for " << config_.num_epochs << " epochs..." << std::endl;

    // Determine split index for validation
    size_t split_idx = static_cast<size_t>(dataset.Size() * (1.0 - config_.validation_split));

    for (int epoch = 0; epoch < config_.num_epochs; ++epoch) {
        double total_loss = 0.0;
        size_t batch_count = 0;

        // Training loop (mini-batch)
        for (size_t batch_start = 0; batch_start < split_idx; batch_start += config_.batch_size) {
            auto [batch_features, batch_labels] = dataset.GetBatch(batch_start, config_.batch_size);

            for (size_t i = 0; i < batch_features.size(); ++i) {
                std::vector<double> output = ForwardPass(batch_features[i]);
                if (output.empty()) continue;

                double predicted = output[0];
                double actual = batch_labels[i];
                double loss = ComputeLoss(predicted, actual);
                total_loss += loss;

                double error = predicted - actual;
                BackwardPass(batch_features[i], error);
            }
            batch_count++;
        }

        double avg_loss = batch_count > 0 ? total_loss / batch_count : 0.0;

        // Print progress every 10 epochs
        if (epoch % 10 == 0 || epoch == config_.num_epochs - 1) {
            std::cout << "[AI Controller] Epoch " << (epoch + 1) << "/" << config_.num_epochs
                      << "  -  Loss: " << avg_loss << std::endl;
        }

        // Simulate training time
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    std::cout << "[AI Controller] Training complete!" << std::endl;
    state_ = ControllerState::kReady;
    return true;
}

PredictionResult<double> AiController::Infer(const std::vector<double>& input) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (state_ != ControllerState::kReady) {
        std::cerr << "[AI Controller] Cannot infer: model not ready (state="
                  << static_cast<int>(state_) << ")" << std::endl;
        return PredictionResult<double>(0.0, 0.0, 0.0);
    }

    auto start_time = std::chrono::high_resolution_clock::now();

    std::vector<double> output = ForwardPass(input);

    auto end_time = std::chrono::high_resolution_clock::now();
    double latency_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();

    double prediction = output.empty() ? 0.0 : output[0];
    double confidence = 0.5 + (std::abs(prediction) * 0.3);
    confidence = std::min(1.0, std::max(0.0, confidence));

    PredictionResult<double> result(prediction, confidence, latency_ms);
    result.model_name = config_.model_name;
    result.model_version = config_.model_version;
    result.raw_output = output;

    return result;
}

TrainingConfig AiController::Optimize() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << "[AI Controller] Running hyperparameter optimization..." << std::endl;

    // Simulate optimization by randomly adjusting hyperparameters
    std::uniform_real_distribution<double> lr_dist(0.0001, 0.01);
    std::uniform_int_distribution<int> layer_dist(1, 6);
    std::uniform_int_distribution<int> hidden_dist(32, 256);

    TrainingConfig optimized = config_;
    optimized.learning_rate = lr_dist(*rng_);
    optimized.num_layers = layer_dist(*rng_);
    optimized.hidden_size = hidden_dist(*rng_);

    std::cout << "[AI Controller] Optimization complete. Suggested learning rate: "
              << optimized.learning_rate << ", layers: " << optimized.num_layers
              << ", hidden size: " << optimized.hidden_size << std::endl;

    return optimized;
}

bool AiController::SaveCheckpoint(const std::string& path) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << "[AI Controller] Saving checkpoint to: " << path << std::endl;

    if (!network_) {
        std::cerr << "[AI Controller] No model to save" << std::endl;
        return false;
    }

    std::ofstream file(path, std::ios::binary);
    if (!file) {
        std::cerr << "[AI Controller] Failed to open file: " << path << std::endl;
        return false;
    }

    // Write header
    file << "TENT-AI-CHECKPOINT-v1\n";
    file << config_.model_name << "\n";
    file << config_.model_version << "\n";
    file << network_->layers.size() << "\n";

    // Write layer parameters
    for (const auto& layer : network_->layers) {
        file << layer.weights.size() << " " << layer.weights[0].size() << "\n";
        for (const auto& row : layer.weights) {
            for (double w : row) {
                file << w << " ";
            }
            file << "\n";
        }
        for (double b : layer.biases) {
            file << b << " ";
        }
        file << "\n";
    }

    std::cout << "[AI Controller] Checkpoint saved successfully" << std::endl;
    return true;
}

bool AiController::LoadCheckpoint(const std::string& path) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::cout << "[AI Controller] Loading checkpoint from: " << path << std::endl;

    std::ifstream file(path);
    if (!file) {
        std::cerr << "[AI Controller] Failed to open checkpoint file" << std::endl;
        return false;
    }

    // Read and verify header
    std::string header;
    std::getline(file, header);
    if (header != "TENT-AI-CHECKPOINT-v1") {
        std::cerr << "[AI Controller] Invalid checkpoint format" << std::endl;
        return false;
    }

    std::cout << "[AI Controller] Checkpoint loaded (simulated)" << std::endl;
    state_ = ControllerState::kReady;
    return true;
}

}  // namespace tent::ai
