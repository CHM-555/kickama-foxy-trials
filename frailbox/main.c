#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>

#include "arena.h"
#include "sandbox.h"

#define VERSION "0.1.0"
#define DEFAULT_REGION_SIZE (1024 * 1024 * 64)

static volatile sig_atomic_t running = 1;

static void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

static void print_banner(void) {
    fprintf(stdout,
        "╔══════════════════════════════════════════╗\n"
        "║       frailbox  -  Sandbox Framework       ║\n"
        "║        Tent of Trials v%s             ║\n"
        "╚══════════════════════════════════════════╝\n\n",
        VERSION);
}

static void print_config(const sandbox_config_t *config) {
    static const char *type_names[] = {
        [SANDBOX_NONE]       = "none",
        [SANDBOX_SECCOMP]    = "seccomp",
        [SANDBOX_NAMESPACE]  = "namespace",
        [SANDBOX_CAPABILITY] = "capability",
        [SANDBOX_CHROOT]    = "chroot",
        [SANDBOX_LANDLOCK]   = "landlock",
    };

    fprintf(stdout, "  sandbox type:       %s\n", type_names[config->type]);
    fprintf(stdout, "  memory limit:       %lu MB\n",
            (unsigned long)(config->memory_limit_bytes / (1024 * 1024)));
    fprintf(stdout, "  cpu limit:          %lu ns\n",
            (unsigned long)config->cpu_limit_ns);
    fprintf(stdout, "  max processes:      %u\n", config->max_processes);
    fprintf(stdout, "  max open fds:       %u\n", config->max_open_fds);
    fprintf(stdout, "  network:            %s\n", config->enable_network ? "enabled" : "disabled");
    fprintf(stdout, "  ptrace:             %s\n", config->enable_ptrace ? "enabled" : "disabled");
    fprintf(stdout, "  rules:              %zu\n", config->rule_count);
    fprintf(stdout, "  chroot:             %s\n",
            config->chroot_path[0] ? config->chroot_path : "(none)");
    fprintf(stdout, "  work dir:           %s\n",
            config->work_dir[0] ? config->work_dir : "(default)");
    fprintf(stdout, "\n");
}

int main(int argc, char *argv[]) {
    int opt;
    int verbose = 0;
    sandbox_type_t sandbox_type = SANDBOX_SECCOMP;
    uint64_t memory_limit_mb = 256;
    uint64_t cpu_limit_ms = 1000;

    static struct option long_options[] = {
        {"sandbox-type",    required_argument, 0, 't'},
        {"memory-limit",    required_argument, 0, 'm'},
        {"cpu-limit",       required_argument, 0, 'c'},
        {"verbose",         no_argument,       0, 'v'},
        {"help",            no_argument,       0, 'h'},
        {"version",         no_argument,       0, 'V'},
        {0, 0, 0, 0}
    };

    while ((opt = getopt_long(argc, argv, "t:m:c:vhV", long_options, NULL)) != -1) {
        switch (opt) {
        case 't':
            if (strcmp(optarg, "seccomp") == 0)
                sandbox_type = SANDBOX_SECCOMP;
            else if (strcmp(optarg, "namespace") == 0)
                sandbox_type = SANDBOX_NAMESPACE;
            else if (strcmp(optarg, "none") == 0)
                sandbox_type = SANDBOX_NONE;
            else {
                fprintf(stderr, "unknown sandbox type: %s\n", optarg);
                return 1;
            }
            break;
        case 'm':
            memory_limit_mb = strtoull(optarg, NULL, 10);
            break;
        case 'c':
            cpu_limit_ms = strtoull(optarg, NULL, 10);
            break;
        case 'v':
            verbose = 1;
            break;
        case 'h':
            fprintf(stdout, "Usage: %s [options]\n\n", argv[0]);
            fprintf(stdout, "Options:\n");
            fprintf(stdout, "  -t, --sandbox-type TYPE   sandbox type (seccomp, namespace, none)\n");
            fprintf(stdout, "  -m, --memory-limit MB     memory limit in megabytes\n");
            fprintf(stdout, "  -c, --cpu-limit MS        CPU time limit in milliseconds\n");
            fprintf(stdout, "  -v, --verbose             verbose output\n");
            fprintf(stdout, "  -h, --help                show this help\n");
            fprintf(stdout, "  -V, --version             show version\n");
            return 0;
        case 'V':
            fprintf(stdout, "frailbox v%s\n", VERSION);
            return 0;
        default:
            return 1;
        }
    }

    if (signal(SIGINT, handle_signal) == SIG_ERR) {
        perror("signal");
        return 1;
    }
    if (signal(SIGTERM, handle_signal) == SIG_ERR) {
        perror("signal");
        return 1;
    }

    print_banner();

    arena_t *arena = arena_create(DEFAULT_REGION_SIZE, ARENA_ZERO_INIT);
    if (!arena) {
        fprintf(stderr, "failed to create arena allocator\n");
        return 1;
    }

    sandbox_config_t config;
    memset(&config, 0, sizeof(config));
    config.type = sandbox_type;
    config.memory_limit_bytes = memory_limit_mb * 1024 * 1024;
    config.cpu_limit_ns = cpu_limit_ms * 1000000;
    config.max_processes = 10;
    config.max_open_fds = 64;
    config.enable_network = 0;
    config.enable_ptrace = 0;

    sandbox_rule_t rule1 = {
        .capability = CAP_FILE_READ,
        .action = ACTION_ALLOW,
        .syscall_number = 0,
        .next = NULL,
    };
    sandbox_rule_t rule2 = {
        .capability = CAP_FILE_WRITE,
        .action = ACTION_DENY,
        .syscall_number = 0,
        .next = NULL,
    };
    rule1.next = &rule2;
    config.rules = &rule1;
    config.rule_count = 2;

    if (verbose) {
        fprintf(stdout, "Sandbox Configuration:\n");
        print_config(&config);
    }

    sandbox_t *sandbox = sandbox_create(&config);
    if (!sandbox) {
        fprintf(stderr, "failed to create sandbox\n");
        arena_destroy(arena);
        return 1;
    }

    if (sandbox_apply(sandbox) != 0) {
        fprintf(stderr, "warning: sandbox_apply failed: %s\n", strerror(errno));
    }

    void *ptr1 = arena_alloc(arena, 1024);
    void *ptr2 = arena_alloc_aligned(arena, 4096, 4096);
    void *ptr3 = arena_calloc(arena, 1, 2048);

    arena_stats_t stats = arena_get_stats(arena);

    if (verbose) {
        fprintf(stdout, "Arena Statistics:\n");
        fprintf(stdout, "  total allocated:     %lu bytes\n",
                (unsigned long)stats.total_allocated);
        fprintf(stdout, "  peak usage:          %lu bytes\n",
                (unsigned long)stats.peak_usage);
        fprintf(stdout, "  current usage:       %lu bytes\n",
                (unsigned long)stats.current_usage);
        fprintf(stdout, "  allocation count:    %lu\n",
                (unsigned long)stats.allocation_count);
        fprintf(stdout, "  region count:        %lu\n",
                (unsigned long)stats.region_count);
        fprintf(stdout, "\n");
    }

    fprintf(stdout, "frailbox: sandbox %s initialized [type=%d, mem=%luMB]\n",
            sandbox_is_active(sandbox) ? "ACTIVE" : "PASSIVE",
            sandbox->config.type,
            (unsigned long)(sandbox->config.memory_limit_bytes / (1024 * 1024)));

    fprintf(stdout, "frailbox: arena allocator running [regions=%lu, used=%lu bytes]\n",
            (unsigned long)stats.region_count,
            (unsigned long)stats.current_usage);

    fprintf(stdout, "frailbox: entering main loop (press Ctrl+C to exit)\n");

    while (running) {
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 100000000 };
        nanosleep(&ts, NULL);
    }

    fprintf(stdout, "\nfrailbox: shutting down...\n");

    sandbox_destroy(sandbox);
    arena_destroy(arena);

    fprintf(stdout, "frailbox: shutdown complete\n");

    (void)ptr1;
    (void)ptr2;
    (void)ptr3;
    return 0;
}
