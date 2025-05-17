#include "camera_handler.h"
#include "config.h"

bool camera_system_init() {
    camera_config_t config = {
        .pin_pwdn       = PWDN_GPIO_NUM,
        .pin_reset      = RESET_GPIO_NUM,
        .pin_xclk       = XCLK_GPIO_NUM,
        .pin_sccb_sda   = SIOD_GPIO_NUM,
        .pin_sccb_scl   = SIOC_GPIO_NUM,
        .pin_d7         = Y9_GPIO_NUM,
        .pin_d6         = Y8_GPIO_NUM,
        .pin_d5         = Y7_GPIO_NUM,
        .pin_d4         = Y6_GPIO_NUM,
        .pin_d3         = Y5_GPIO_NUM,
        .pin_d2         = Y4_GPIO_NUM,
        .pin_d1         = Y3_GPIO_NUM,
        .pin_d0         = Y2_GPIO_NUM,
        .pin_vsync      = VSYNC_GPIO_NUM,
        .pin_href       = HREF_GPIO_NUM,
        .pin_pclk       = PCLK_GPIO_NUM,
        .xclk_freq_hz   = 20000000,
        .pixel_format   = PIXFORMAT_JPEG,
        .frame_size     = FRAMESIZE_QSXGA,
        .jpeg_quality   = 15,              // lower means higher quality
        .fb_count       = 2,               
        .fb_location    = CAMERA_FB_IN_PSRAM,
        .grab_mode      = CAMERA_GRAB_LATEST,
    };

    if (esp_camera_init(&config) != ESP_OK) {
        LOG_PRINTLN("[ERROR]  Camera init failed");
        return false;
    }

    sensor_t* sensor = esp_camera_sensor_get();
    if (sensor) {
        sensor->set_hmirror(sensor, 1);
    }
    
    LOG_PRINTLN("[INFO]  Camera initialized");
    return true;
}

camera_fb_t* camera_capture_frame() {
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
        LOG_PRINTLN("[ERROR]  Camera capture failed");
    }
    return fb;
}

void camera_return_frame(camera_fb_t* fb) {
    if (fb) {
        esp_camera_fb_return(fb);
    }
}