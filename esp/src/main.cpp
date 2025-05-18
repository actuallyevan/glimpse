#include "audio_handler.h"
#include "ble_handler.h"
#include "camera_handler.h"
#include "config.h"
#include <Arduino.h>

volatile bool isReady = true; // ready to take and send image

void send_jpeg() {
  ble_keep_alive();
  delay(50); // wait for iOS to be ready

  camera_fb_t *fb = camera_capture_frame();
  if (!fb) {
    LOG_PRINTLN("[ERROR]  Camera capture failed");
    isReady = true;
    return;
  }

  LOG_PRINTF("[INFO]  Captured image of size %u\n", fb->len);
  ble_send_jpeg_data(fb->buf, fb->len);
  camera_return_frame(fb);
}

void setup() {
  Serial.begin(115200);
  delay(3000); // wait for serial monitor

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!psramInit()) {
    LOG_PRINTLN("[ERROR]  PSRAM init failed");
    while (true) {
      delay(10000);
    } // stop execution
  }
  LOG_PRINTF("[INFO]  PSRAM Size: %u bytes, Free: %u bytes\n", ESP.getPsramSize(), ESP.getFreePsram());

  audio_system_init();

  if (!camera_system_init()) {
    LOG_PRINTLN("[ERROR]  Camera init failed");
    while (true) {
      delay(10000);
    } // stop execution
  }

  ble_system_init();

  LOG_PRINTLN("[INFO]  Setup complete");
}

void loop() {

  if (digitalRead(BUTTON_PIN) == LOW && isReady) {
    if (active_l2cap_channel && l2cap_callbacks && l2cap_callbacks->connected) {
      LOG_PRINTLN("[INFO]  Sending image");
      isReady = false;
      send_jpeg();
    } else {
      LOG_PRINTLN("[ERROR]  Cannot send image");
    }
  }

  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.equalsIgnoreCase("send")) {
      if (isReady && active_l2cap_channel && l2cap_callbacks && l2cap_callbacks->connected) {
        LOG_PRINTLN("[INFO]  Sending image");
        isReady = false;
        send_jpeg();
      } else {
        LOG_PRINTLN("[ERROR]  Cannot send image");
      }
    }
  }

  delay(50);
}