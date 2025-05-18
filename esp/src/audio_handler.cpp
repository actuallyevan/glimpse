#include "audio_handler.h"
#include "config.h"

I2SClass I2S_audio;
QueueHandle_t audioQueue = NULL;
TaskHandle_t audioTaskHandle = NULL;

static void process_and_play_audio(AudioPlayData_t audioData) {
  if (audioData.buffer == nullptr || audioData.length == 0) {
    LOG_PRINTLN("[ERROR]  No valid audio data to play");
    if (audioData.buffer) {
      free(audioData.buffer);
    }
    return;
  }

  I2S_audio.setPins(I2S_PIN_BCK, I2S_PIN_WS, I2S_PIN_DOUT, I2S_PIN_DIN, I2S_PIN_MCK);
  if (!I2S_audio.begin(I2S_MODE_STD, 44100, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) {
    LOG_PRINTLN("[ERROR]  Failed to initialize I2S");
    free(audioData.buffer);
    return;
  }

  LOG_PRINTF("[INFO]  Playing MP3 data of size %u\n", audioData.length);
  bool success = I2S_audio.playMP3(audioData.buffer, audioData.length);
  LOG_PRINTLN(success ? "[INFO]  MP3 playback finished." : "[ERROR]  MP3 playback failed.");

  I2S_audio.end();
  LOG_PRINTLN("[INFO]  I2S ended");

  free(audioData.buffer);
  LOG_PRINTLN("[INFO]  PSRAM audio buffer freed");
}

void audio_player_task(void *pvParameters) {
  AudioPlayData_t receivedAudioData;
  LOG_PRINTLN("[INFO]  Audio task started");
  for (;;) {
    if (xQueueReceive(audioQueue, &receivedAudioData, portMAX_DELAY) == pdPASS) {
      LOG_PRINTLN("[INFO]  Audio task received data from queue");
      process_and_play_audio(receivedAudioData);
      LOG_PRINTLN("[INFO]  Audio task finished");
      isReady = true;
    }
  }
}

void audio_system_init() {
  audioQueue = xQueueCreate(2, sizeof(AudioPlayData_t)); // although we only need 1, we just use a queue with max 2
  if (audioQueue == NULL) {
    LOG_PRINTLN("[ERROR]  Error creating audio queue");
  }

  xTaskCreatePinnedToCore(audio_player_task, "AudioPlayerTask", 8192, NULL, 5, &audioTaskHandle, APP_CPU_NUM);

  if (audioTaskHandle == NULL) {
    LOG_PRINTLN("[ERROR]  Failed to create audio task");
  }
}

bool queue_audio_data_for_playback(uint8_t *buffer, size_t length) {
  AudioPlayData_t dataToPlay;
  dataToPlay.buffer = buffer;
  dataToPlay.length = length;

  if (xQueueSend(audioQueue, &dataToPlay, pdMS_TO_TICKS(100)) != pdPASS) {
    LOG_PRINTLN("[ERROR]  Failed to send audio data to queue, freeing buffer");
    free(buffer);
    return false;
  }
  return true;
}

void audio_system_reset_playback_state() {
  if (audioQueue != NULL) {
    xQueueReset(audioQueue);
    LOG_PRINTLN("[INFO]  Audio queue has been reset");
  }
}