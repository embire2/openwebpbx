/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Independent, credential-free ABI/thread handoff probe for exact MSI pthread. */
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    pthread_t parent;
    int release;
    int arrived;
    int failed;
} handoff;

static void *worker(void *argument)
{
    handoff *state = (handoff *)argument;
    if (pthread_mutex_lock(&state->mutex)) return NULL;
    state->arrived = 1;
    if (pthread_equal(pthread_self(), state->parent)) state->failed = 1;
    if (pthread_cond_signal(&state->condition)) state->failed = 1;
    while (!state->release) {
        if (pthread_cond_wait(&state->condition, &state->mutex)) {
            state->failed = 1;
            break;
        }
    }
    if (pthread_mutex_unlock(&state->mutex)) state->failed = 1;
    return state;
}

int main(void)
{
    unsigned int iteration;
    if (sizeof(pthread_t) != 16 || sizeof(pthread_mutex_t) != 8 ||
        PTW32_VERSION_MAJOR != 2 || PTW32_VERSION_MINOR != 10) return 1;
    for (iteration = 0; iteration < 32; iteration++) {
        handoff state = {0};
        pthread_t thread;
        void *returned = NULL;
        state.parent = pthread_self();
        if (pthread_mutex_init(&state.mutex, NULL) ||
            pthread_cond_init(&state.condition, NULL) ||
            pthread_mutex_lock(&state.mutex)) return 2;
        if (pthread_create(&thread, NULL, worker, &state)) return 3;
        while (!state.arrived) {
            if (pthread_cond_wait(&state.condition, &state.mutex)) return 4;
        }
        if (pthread_equal(thread, state.parent)) return 5;
        state.release = 1;
        if (pthread_cond_signal(&state.condition) ||
            pthread_mutex_unlock(&state.mutex) ||
            pthread_join(thread, &returned)) return 6;
        if (returned != &state || state.failed) return 7;
        if (pthread_cond_destroy(&state.condition) ||
            pthread_mutex_destroy(&state.mutex)) return 8;
    }
    puts("PASS exact MSI pthread: 32 real identity/handoff/join cycles.");
    return 0;
}
