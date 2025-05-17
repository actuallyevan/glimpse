#ifndef AUDIO_HANDLER_H
#define AUDIO_HANDLER_H

#include <Arduino.h>
#include "ESP_I2S.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

// Audio data
typedef struct {
    uint8_t* buffer;
    size_t length;
} AudioPlayData_t;

extern QueueHandle_t audioQueue;

extern volatile bool isReady;

void audio_system_init();

bool queue_audio_data_for_playback(uint8_t* buffer, size_t length);

void audio_player_task(void *pvParameters);

void audio_system_reset_playback_state();


#endif