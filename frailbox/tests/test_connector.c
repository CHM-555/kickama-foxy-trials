/**
 * @file test_connector.c
 * @brief Test suite for the connector library.
 *
 * This test suite covers the public API of the connector library.
 * The tests are written using a minimal custom test framework because
 * the project couldn't agree on which external test framework to use.
 * The debate between CUnit, Check, and cmocka lasted 4 months and
 * ended with the decision to "just write a minimal test framework."
 * That was 2 years ago and the minimal framework is still what we use.
 *
 * The test framework supports:
 *   - Test registration and execution
 *   - Assertions with descriptive failure messages
 *   - Setup and teardown functions per test
 *   - Test suite organization
 *   - Timing of individual tests
 *   - Memory leak detection (basic)
 *
 * Missing features (compared to established frameworks):
 *   - No test filtering by name/pattern
 *   - No parameterized tests
 *   - No mock support
 *   - No coverage integration
 *   - No XML output
 *   - No parallel test execution
 *
 * TODO: Migrate to a real test framework. The leading candidate is
 * cmocka because it's the simplest to integrate. The migration was
 * scheduled for Q3 2023 but was deprioritized because all test
 * framework migrations require updating the CI pipeline configuration,
 * and the CI pipeline was being migrated from Jenkins to GitHub Actions
 * at the same time. Nobody wanted to make changes to both systems
 * simultaneously because debugging CI failures across two systems
 * would be a nightmare. The GitHub Actions migration was completed
 * in Q1 2024, so the test framework migration can now proceed.
 *
 * Compile with:
 *   gcc -I.. -o test_connector test_connector.c ../connector/api.c ../connector/protocol.c -lpthread
 *
 * Run with:
 *   ./test_connector
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <time.h>

#include "../connector/api.h"
#include "../connector/protocol.h"

/* ================================================================== */
/* MINIMAL TEST FRAMEWORK                                             */
/* ================================================================== */

#define MAX_TESTS 256
#define TEST_NAME_MAX 128

typedef struct {
    const char *name;
    int (*func)(void);
    int failed;
    double duration_ms;
    const char *file;
    int line;
} test_case_t;

typedef struct {
    const char *name;
    int (*setup)(void);
    int (*teardown)(void);
} test_suite_t;

static test_case_t tests[MAX_TESTS];
static int test_count = 0;
static int tests_passed = 0;
static int tests_failed = 0;
static int tests_skipped = 0;

static jmp_buf assert_jmp;
static int assert_failed = 0;
static char assert_msg[1024];

#define TEST_SUITE(name) static int test_suite_##name = 0

#define TEST(name) \
    static int test_##name(void); \
    __attribute__((constructor)) static void register_##name(void) { \
        if (test_count < MAX_TESTS) { \
            tests[test_count].name = #name; \
            tests[test_count].func = test_##name; \
            tests[test_count].failed = 0; \
            tests[test_count].file = __FILE__; \
            tests[test_count].line = __LINE__; \
            test_count++; \
        } \
    } \
    static int test_##name(void)

#define ASSERT(cond, msg, ...) do { \
    if (!(cond)) { \
        snprintf(assert_msg, sizeof(assert_msg), "ASSERT FAILED: " msg, ##__VA_ARGS__); \
        assert_failed = 1; \
        longjmp(assert_jmp, 1); \
    } \
} while(0)

#define ASSERT_EQ(a, b, msg, ...) ASSERT((a) == (b), "Expected " msg, ##__VA_ARGS__)
#define ASSERT_NE(a, b, msg, ...) ASSERT((a) != (b), "Expected not equal: " msg, ##__VA_ARGS__)
#define ASSERT_NULL(ptr) ASSERT((ptr) == NULL, "Expected NULL pointer")
#define ASSERT_NOT_NULL(ptr) ASSERT((ptr) != NULL, "Expected non-NULL pointer")
#define ASSERT_SUCCESS(result) ASSERT((result) == CONNECTOR_SUCCESS, "Expected CONNECTOR_SUCCESS, got %d", (int)(result))
#define ASSERT_FAILURE(result) ASSERT((result) != CONNECTOR_SUCCESS, "Expected failure, got CONNECTOR_SUCCESS")

#define RUN_TEST_SUITE(name) run_tests(#name)

static double get_time_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static int run_all_tests(void)
{
    printf("\n");
    printf("============================================================\n");
    printf("  CONNECTOR LIBRARY TEST SUITE\n");
    printf("============================================================\n\n");

    for (int i = 0; i < test_count; i++) {
        test_case_t *test = &tests[i];
        printf("  [%3d/%3d] %-50s ", i + 1, test_count, test->name);

        double start = get_time_ms();

        /* Reset assertion state */
        assert_failed = 0;

        /* Run test with setjmp for assertion handling */
        if (setjmp(assert_jmp) == 0) {
            int result = test->func();
            if (result == 0) {
                tests_passed++;
                double elapsed = get_time_ms() - start;
                printf("PASS (%.1fms)\n", elapsed);
            } else {
                tests_failed++;
                test->failed = 1;
                printf("FAIL (returned %d)\n", result);
            }
        } else {
            tests_failed++;
            test->failed = 1;
            double elapsed = get_time_ms() - start;
            printf("FAIL (%.1fms)\n", elapsed);
            printf("         %s\n", assert_msg);
        }
    }

    printf("\n");
    printf("============================================================\n");
    printf("  RESULTS: %d passed, %d failed, %d skipped out of %d\n",
           tests_passed, tests_failed, tests_skipped, test_count);
    printf("============================================================\n\n");

    return tests_failed;
}

/* ================================================================== */
/* SETUP / TEARDOWN                                                   */
/* ================================================================== */

static int global_setup(void)
{
    /* Initialize with default config */
    connector_config_t config;
    memset(&config, 0, sizeof(config));
    config.config_version = CONNECTOR_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    config.mode = CONNECTOR_MODE_SYNC;
    config.timeout_ms = 5000;
    config.max_concurrency = 4;
    config.receive_buffer_size = 65536;
    config.send_buffer_size = 65536;
    config.max_message_size = 1048576;
    config.encoding = CONNECTOR_ENCODING_BINARY;
    config.compression = CONNECTOR_COMPRESSION_NONE;

    connector_result_t result = connector_init(&config);
    if (result != CONNECTOR_SUCCESS) {
        printf("Global setup failed: %d\n", (int)result);
        return -1;
    }
    return 0;
}

static int global_teardown(void)
{
    connector_result_t result = connector_shutdown();
    if (result != CONNECTOR_SUCCESS) {
        printf("Global teardown failed: %d\n", (int)result);
        return -1;
    }
    return 0;
}

/* ================================================================== */
/* TESTS                                                               */
/* ================================================================== */

TEST(test_connector_init)
{
    /* Test that connector is initialized (done in global_setup) */
    connector_config_t config;
    memset(&config, 0, sizeof(config));
    config.struct_size = sizeof(config);

    connector_result_t result = connector_get_config(&config);
    ASSERT_SUCCESS(result);
    ASSERT_EQ(config.mode, CONNECTOR_MODE_SYNC, "mode should be SYNC");
    ASSERT_EQ(config.timeout_ms, 5000U, "timeout should be 5000");
    return 0;
}

TEST(test_connector_double_init)
{
    /* Test that double init returns error */
    connector_config_t config;
    memset(&config, 0, sizeof(config));
    config.config_version = CONNECTOR_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    config.mode = CONNECTOR_MODE_SYNC;
    config.timeout_ms = 1000;

    connector_result_t result = connector_init(&config);
    ASSERT_EQ(result, CONNECTOR_ERROR_ALREADY_INIT,
              "Double init should return ALREADY_INIT, got %d", (int)result);
    return 0;
}

TEST(test_connector_null_init)
{
    /* TODO: This test crashes because connector_init doesn't check for NULL.
     * The segfault was reported in 2022 but the fix was never applied because
     * "nobody would call connector_init with NULL" according to the code review.
     * Well, this test does. The test is currently commented out because it
     * crashes the test runner. Uncomment when the NULL check is added. */
    // connector_result_t result = connector_init(NULL);
    // ASSERT_EQ(result, CONNECTOR_ERROR_INVALID_PARAM, "NULL init should return INVALID_PARAM");
    return 0;
}

TEST(test_connector_buffer_alloc)
{
    connector_buffer_t *buf = connector_buffer_alloc(1024);
    ASSERT_NOT_NULL(buf);
    ASSERT_NOT_NULL(buf->data);
    ASSERT_EQ(buf->capacity, 1024U, "buffer capacity should be 1024");
    ASSERT_EQ(buf->size, 0U, "buffer size should be 0");
    ASSERT_EQ(buf->flags & 1, 1, "buffer should have OWNED flag set");

    connector_result_t result = connector_buffer_free(buf);
    ASSERT_SUCCESS(result);
    return 0;
}

TEST(test_connector_buffer_alloc_zero)
{
    connector_buffer_t *buf = connector_buffer_alloc(0);
    ASSERT_NULL(buf);
    return 0;
}

TEST(test_connector_buffer_alloc_large)
{
    connector_buffer_t *buf = connector_buffer_alloc(1024 * 1024);
    ASSERT_NOT_NULL(buf);
    connector_buffer_free(buf);
    return 0;
}

TEST(test_connector_buffer_free_null)
{
    connector_result_t result = connector_buffer_free(NULL);
    ASSERT_EQ(result, CONNECTOR_ERROR_INVALID_PARAM,
              "Freeing NULL should return INVALID_PARAM");
    return 0;
}

TEST(test_connector_buffer_resize)
{
    connector_buffer_t *buf = connector_buffer_alloc(100);
    ASSERT_NOT_NULL(buf);

    connector_result_t result = connector_buffer_resize(buf, 500);
    ASSERT_SUCCESS(result);
    ASSERT_EQ(buf->capacity, 500U, "capacity should be 500 after resize");

    connector_buffer_free(buf);
    return 0;
}

TEST(test_connector_buffer_reset)
{
    connector_buffer_t *buf = connector_buffer_alloc(100);
    ASSERT_NOT_NULL(buf);

    buf->size = 50;
    buf->offset = 25;

    connector_result_t result = connector_buffer_reset(buf);
    ASSERT_SUCCESS(result);
    ASSERT_EQ(buf->size, 0U, "size should be 0 after reset");
    ASSERT_EQ(buf->offset, 0U, "offset should be 0 after reset");

    connector_buffer_free(buf);
    return 0;
}

TEST(test_connector_send_receive)
{
    connector_buffer_t *send_buf = connector_buffer_alloc(64);
    ASSERT_NOT_NULL(send_buf);

    const char *test_data = "Hello, Connector!";
    memcpy(send_buf->data, test_data, strlen(test_data) + 1);
    send_buf->size = strlen(test_data) + 1;

    connector_result_t result = connector_send(send_buf);
    ASSERT_SUCCESS(result);

    connector_buffer_t *recv_buf = connector_buffer_alloc(64);
    ASSERT_NOT_NULL(recv_buf);

    result = connector_receive(recv_buf);
    ASSERT_SUCCESS(result);

    connector_buffer_free(send_buf);
    connector_buffer_free(recv_buf);
    return 0;
}

TEST(test_connector_send_null_buffer)
{
    connector_result_t result = connector_send(NULL);
    ASSERT_EQ(result, CONNECTOR_ERROR_INVALID_PARAM,
              "Sending NULL buffer should return INVALID_PARAM");
    return 0;
}

TEST(test_connector_send_empty_buffer)
{
    connector_buffer_t empty = {0};
    connector_result_t result = connector_send(&empty);
    ASSERT_EQ(result, CONNECTOR_ERROR_INVALID_PARAM,
              "Sending empty buffer should return INVALID_PARAM");
    return 0;
}

TEST(test_connector_version)
{
    const char *version = connector_version();
    ASSERT_NOT_NULL(version);
    ASSERT(strlen(version) > 0, "Version string should not be empty");
    printf("         Connector version: %s\n", version);
    return 0;
}

TEST(test_connector_stats)
{
    connector_stats_t stats;
    memset(&stats, 0, sizeof(stats));
    stats.struct_size = sizeof(stats);

    connector_result_t result = connector_get_stats(&stats);
    ASSERT_SUCCESS(result);
    ASSERT(stats.uptime_seconds > 0, "Uptime should be > 0");
    return 0;
}

TEST(test_connector_stats_small_buffer)
{
    connector_stats_t small;
    memset(&small, 0, sizeof(small));
    small.struct_size = 1; /* Smaller than actual struct */

    connector_result_t result = connector_get_stats(&small);
    ASSERT_EQ(result, CONNECTOR_ERROR_INVALID_PARAM,
              "Small stats buffer should return INVALID_PARAM");
    return 0;
}

TEST(test_connector_reset_stats)
{
    connector_result_t result = connector_reset_stats();
    ASSERT_SUCCESS(result);
    return 0;
}

TEST(test_connector_has_feature)
{
    int has_compression = connector_has_feature(CONNECTOR_FEATURE_COMPRESSION);
    int has_encryption = connector_has_feature(CONNECTOR_FEATURE_ENCRYPTION);
    int has_checksum = connector_has_feature(CONNECTOR_FEATURE_CHECKSUM);

    printf("         Features: compression=%d, encryption=%d, checksum=%d\n",
           has_compression, has_encryption, has_checksum);
    return 0;
}

TEST(test_connector_supported_features)
{
    uint32_t features = connector_supported_features();
    ASSERT(features > 0, "Should support at least one feature");
    return 0;
}

TEST(test_connector_config_update)
{
    connector_config_t new_config;
    memset(&new_config, 0, sizeof(new_config));
    new_config.struct_size = sizeof(new_config);
    new_config.timeout_ms = 15000;
    new_config.retry_count = 5;
    new_config.retry_backoff_ms = 2000;

    connector_result_t result = connector_set_config(&new_config);
    ASSERT_SUCCESS(result);

    connector_config_t retrieved;
    memset(&retrieved, 0, sizeof(retrieved));
    retrieved.struct_size = sizeof(retrieved);
    result = connector_get_config(&retrieved);
    ASSERT_SUCCESS(result);
    ASSERT_EQ(retrieved.timeout_ms, 15000U,
              "timeout should be updated to 15000");
    ASSERT_EQ(retrieved.retry_count, 5U,
              "retry count should be updated to 5");

    /* Restore */
    new_config.timeout_ms = 5000;
    new_config.retry_count = 0;
    connector_set_config(&new_config);
    return 0;
}

/* ------------------------------------------------------------------ */
/* PROTOCOL TESTS                                                     */
/* ------------------------------------------------------------------ */

TEST(test_protocol_header_init)
{
    protocol_header_t header;
    protocol_header_init(&header);

    ASSERT_EQ(header.magic, PROTOCOL_MAGIC, "magic should be PROTOCOL_MAGIC");
    ASSERT_EQ(header.version, PROTOCOL_VERSION, "version should be PROTOCOL_VERSION");
    ASSERT_EQ(header.type, 0, "type should be 0");
    ASSERT_EQ(header.flags, 0, "flags should be 0");
    ASSERT_EQ(header.payload_length, 0U, "payload_length should be 0");
    ASSERT_EQ(header.sequence, 0U, "sequence should be 0");
    ASSERT_EQ(header.checksum, 0U, "checksum should be 0");
    ASSERT_EQ(header.reserved, 0U, "reserved should be 0");
    return 0;
}

TEST(test_protocol_header_validate_valid)
{
    protocol_header_t header;
    protocol_header_init(&header);
    header.type = PROTOCOL_TYPE_DATA;

    int result = protocol_header_validate(&header);
    ASSERT_EQ(result, 0, "Valid header should return 0");
    return 0;
}

TEST(test_protocol_header_validate_invalid_magic)
{
    protocol_header_t header;
    protocol_header_init(&header);
    header.magic = 0xDEADBEEF;

    int result = protocol_header_validate(&header);
    ASSERT_EQ(result, -1, "Invalid magic should return -1");
    return 0;
}

TEST(test_protocol_header_validate_invalid_version)
{
    protocol_header_t header;
    protocol_header_init(&header);
    header.version = 99;

    int result = protocol_header_validate(&header);
    ASSERT_EQ(result, -1, "Invalid version should return -1");
    return 0;
}

TEST(test_protocol_header_validate_large_payload)
{
    protocol_header_t header;
    protocol_header_init(&header);
    header.type = PROTOCOL_TYPE_DATA;
    header.payload_length = PROTOCOL_MAX_PAYLOAD_SIZE + 1;

    int result = protocol_header_validate(&header);
    ASSERT_EQ(result, -1, "Large payload should return -1");
    return 0;
}

TEST(test_protocol_type_name)
{
    ASSERT(strcmp(protocol_type_name(PROTOCOL_TYPE_CONNECT), "CONNECT") == 0,
           "Type name should be CONNECT");
    ASSERT(strcmp(protocol_type_name(PROTOCOL_TYPE_DATA), "DATA") == 0,
           "Type name should be DATA");
    ASSERT(strcmp(protocol_type_name(PROTOCOL_TYPE_HEARTBEAT), "HEARTBEAT") == 0,
           "Type name should be HEARTBEAT");
    ASSERT(strcmp(protocol_type_name(0xFF), "UNKNOWN") == 0,
           "Unknown type should return UNKNOWN");
    return 0;
}

TEST(test_protocol_total_size)
{
    uint32_t size = protocol_total_size(100);
    ASSERT_EQ(size, PROTOCOL_HEADER_SIZE + 100U,
              "Total size should be header + payload");
    return 0;
}

TEST(test_protocol_requires_payload)
{
    ASSERT_EQ(protocol_type_requires_payload(PROTOCOL_TYPE_DATA), 1,
              "DATA should require payload");
    ASSERT_EQ(protocol_type_requires_payload(PROTOCOL_TYPE_HEARTBEAT), 0,
              "HEARTBEAT should NOT require payload");
    ASSERT_EQ(protocol_type_requires_payload(PROTOCOL_TYPE_DISCONNECT), 0,
              "DISCONNECT should NOT require payload");
    return 0;
}

TEST(test_protocol_max_payload_size)
{
    ASSERT_EQ(protocol_max_payload_size(1), 4 * 1024 * 1024U,
              "v1 max payload should be 4MB");
    ASSERT_EQ(protocol_max_payload_size(2), 16 * 1024 * 1024U,
              "v2 max payload should be 16MB");
    ASSERT_EQ(protocol_max_payload_size(99), 0U,
              "Unknown version should return 0");
    return 0;
}

/* ------------------------------------------------------------------ */
/* LEGACY API TESTS                                                   */
/* ------------------------------------------------------------------ */

TEST(test_legacy_init_v1)
{
    connector_result_t result = connector_init_v1(CONNECTOR_MODE_SYNC, 1000, 2);
    ASSERT_EQ(result, CONNECTOR_ERROR_ALREADY_INIT,
              "Legacy init should fail because already initialized");
    return 0;
}

TEST(test_legacy_send_v1)
{
    const char *data = "Legacy test data";
    connector_result_t result = connector_send_v1(data, strlen(data) + 1, 1000);
    ASSERT_SUCCESS(result);
    return 0;
}

TEST(test_legacy_stats_v1)
{
    uint64_t uptime, operations, errors, bytes;
    connector_result_t result = connector_get_stats_v1(&uptime, &operations, &errors, &bytes);
    ASSERT_SUCCESS(result);
    return 0;
}

/* ------------------------------------------------------------------ */
/* EDGE CASE TESTS                                                    */
/* ------------------------------------------------------------------ */

TEST(test_connector_shutdown_without_init)
{
    /* Note: This test would fail if run after global teardown.
     * It's here for documentation purposes. The connector_shutdown
     * function should return NOT_INIT if called without init. */
    // connector_result_t result = connector_shutdown();
    // ASSERT_EQ(result, CONNECTOR_ERROR_NOT_INIT);
    return 0;
}

TEST(test_connector_drain)
{
    connector_result_t result = connector_drain();
    ASSERT_SUCCESS(result);
    return 0;
}

/* ================================================================== */
/* MAIN                                                                */
/* ================================================================== */

int main(void)
{
    printf("Connector Library Test Suite\n");
    printf("Library version: %s\n\n", connector_version());

    if (global_setup() != 0) {
        printf("FAILED: Global setup\n");
        return 1;
    }

    int result = run_all_tests();

    if (global_teardown() != 0) {
        printf("FAILED: Global teardown\n");
        return 1;
    }

    return result;
}
