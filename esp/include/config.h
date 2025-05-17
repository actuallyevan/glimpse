#ifndef CONFIG_H
#define CONFIG_H

/*
In addition to these settings, there are more nimBLE settings to configure in the README.
*/

// Debug printing
#define ENABLE_LOGGING 1 // 1 to enable logging, 0 to disable logging

#if ENABLE_LOGGING
  #include <Arduino.h>
  #define LOG_PRINT(x) Serial.print(x)
  #define LOG_PRINTLN(x) Serial.println(x)
  #define LOG_PRINTF(fmt, ...) Serial.printf(fmt, ##__VA_ARGS__)
#else
  #define LOG_PRINT(x)
  #define LOG_PRINTLN(x)
  #define LOG_PRINTF(fmt, ...)
#endif

// BLE parameters
// https://www.uuidgenerator.net/ to generate UUIDs
#define SERVICE_UUID        "dcbc7255-1e9e-49a0-a360-b0430b6c6905"
#define CHARACTERISTIC_UUID "371a55c8-f251-4ad2-90b3-c7c195b049be"
#define L2CAP_PSM           150 
#define L2CAP_MTU           1251    // 1251 works well with iPhone

// I2S pins
#define I2S_PIN_BCK  3
#define I2S_PIN_WS   2
#define I2S_PIN_DOUT 4
#define I2S_PIN_DIN -1
#define I2S_PIN_MCK -1

// Camera pins (OV5640)
#define PWDN_GPIO_NUM     -1
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     10
#define SIOD_GPIO_NUM     40
#define SIOC_GPIO_NUM     39

#define Y9_GPIO_NUM       48
#define Y8_GPIO_NUM       11
#define Y7_GPIO_NUM       12
#define Y6_GPIO_NUM       14
#define Y5_GPIO_NUM       16
#define Y4_GPIO_NUM       18
#define Y3_GPIO_NUM       17
#define Y2_GPIO_NUM       15
#define VSYNC_GPIO_NUM    38
#define HREF_GPIO_NUM     47
#define PCLK_GPIO_NUM     13

// Button
#define BUTTON_PIN 9

#endif