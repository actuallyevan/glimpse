#ifndef CAMERA_HANDLER_H
#define CAMERA_HANDLER_H

#include "esp_camera.h"
#include <Arduino.h>

bool camera_system_init();

camera_fb_t *camera_capture_frame();

void camera_return_frame(camera_fb_t *fb);

#endif