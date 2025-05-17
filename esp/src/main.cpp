#include <Arduino.h>
#include "config.h"
#include "audio_handler.h"
#include "ble_handler.h"
#include "camera_handler.h"

volatile bool isReady = true; // ready to take and send image

void send_jpeg() {
    ble_keep_alive();
    delay(50); // wait for iOS to be ready

    camera_fb_t* fb = camera_capture_frame();
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
    delay(3000);    // wait for serial monitor

    pinMode(BUTTON_PIN, INPUT_PULLUP);

    if (!psramInit()) {
        LOG_PRINTLN("[ERROR]  PSRAM init failed");
        while (true) { delay(10000); }  // stop execution
    }
    LOG_PRINTF("[INFO]  PSRAM Size: %u bytes, Free: %u bytes\n", ESP.getPsramSize(), ESP.getFreePsram());
    
    audio_system_init();
    
    if (!camera_system_init()) {
        LOG_PRINTLN("[ERROR]  Camera init failed");
        while (true) { delay(10000); }  // stop execution
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

/*
#include <Arduino.h>

volatile bool isReady = true;

// bluetooth related below
#include <NimBLEDevice.h>
#include <NimBLEL2CAPChannel.h>
// See https://www.uuidgenerator.net/ for generating UUIDs
#define SERVICE_UUID        "dcbc7255-1e9e-49a0-a360-b0430b6c6905"
#define CHARACTERISTIC_UUID "371a55c8-f251-4ad2-90b3-c7c195b049be"
#define L2CAP_CHANNEL       150
#define L2CAP_MTU           1251

// I2S Audio related
#include "ESP_I2S.h"
I2SClass I2S;

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

QueueHandle_t audioQueue = NULL;
TaskHandle_t audioTaskHandle = NULL;

// This struct can be used to pass data to the audio task
typedef struct {
    uint8_t* buffer;
    size_t length;
} AudioPlayData_t;

static NimBLECharacteristic* characteristic;

void doorBell() {
    Serial.println("Doorbell");
    static uint8_t token = 1;
    characteristic->setValue(&token, 1);
    characteristic->notify();
}


// This function will now run in the dedicated audio task
void processAndPlayAudio(AudioPlayData_t audioData) {
    if (audioData.buffer == nullptr || audioData.length == 0) {
        Serial.println("Audio Task: No valid audio data to play.");
        if (audioData.buffer) { // Should be null if length is 0, but good practice
            free(audioData.buffer);
        }
        return;
    }

    Serial.println("Audio Task: Attempting to play received MP3 audio...");
    I2S.setPins(3, 2, 4, -1, -1); //SCK, WS, SDOUT, SDIN, MCLK
    if (!I2S.begin(I2S_MODE_STD, 44100, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) {
        Serial.println("Audio Task: Failed to initialize I2S.");
        free(audioData.buffer);
        return;
    }

    Serial.printf("Audio Task: Playing MP3 data of size %u bytes...\n", audioData.length);
    bool success = I2S.playMP3(audioData.buffer, audioData.length);
    Serial.println(success ? "Audio Task: MP3 playback finished." : "Audio Task: MP3 playback failed.");
    
    I2S.end();
    Serial.println("Audio Task: I2S ended.");

    free(audioData.buffer); // Free the buffer passed to this task
    Serial.println("Audio Task: PSRAM audio buffer freed.");
}

void audioPlayerTask(void *pvParameters) {
    AudioPlayData_t receivedAudioData;
    Serial.println("Audio Player Task started.");
    for (;;) {
        if (xQueueReceive(audioQueue, &receivedAudioData, portMAX_DELAY) == pdPASS) {
            Serial.println("Audio Player Task: Received data from queue.");
            processAndPlayAudio(receivedAudioData);
            Serial.println("Audio Player Task: Finished processing audio.");
            isReady = true;
        }
    }
}

class GATTCallbacks : public BLEServerCallbacks {
public:
    void onConnect(BLEServer* pServer, BLEConnInfo& info) {
        Serial.println("GATT connection established");
        pServer->setDataLen(info.getConnHandle(), 251);
        BLEDevice::getServer()->updateConnParams(info.getConnHandle(), 12, 12, 0, 200);
    }

    void onDisconnect(BLEServer* pServer, BLEConnInfo& info) {
        Serial.println("GATT disconnected, advertising again");
        pServer->getAdvertising()->start();
    }
};

class L2CAPChannelCallbacks : public BLEL2CAPChannelCallbacks {
public:
    bool connected = false;
    size_t numberOfReceivedBytes = 0;

    uint8_t* psram_audio_buffer = nullptr;
    size_t expected_audio_length = 0;
    size_t current_audio_received_count = 0;

    void onConnect(NimBLEL2CAPChannel* channel, uint16_t negotiatedMTU) {
        Serial.printf("L2CAP channel established (MTU %u)\n", negotiatedMTU);
        connected = true;
        numberOfReceivedBytes = 0;
    }

    void onRead(NimBLEL2CAPChannel* channel, std::vector<uint8_t>& data) {
        if (data.empty()) {
            return;
        }

        size_t data_idx = 0;
        size_t data_len = data.size();

        if (expected_audio_length == 0) {
            if (data_len < 4) {
                Serial.println("Error: Received data too short for length header.");
                return;
            }

            expected_audio_length = static_cast<size_t>(data[0]) |
                                    (static_cast<size_t>(data[1]) << 8) |
                                    (static_cast<size_t>(data[2]) << 16) |
                                    (static_cast<size_t>(data[3]) << 24);

            doorBell();
            
            Serial.printf("Expecting audio data of length: %u bytes\n", expected_audio_length);

            if (expected_audio_length == 0) {
                 Serial.println("Received zero length for audio data. Ignoring.");
                 return;
            }
            
            if (psram_audio_buffer != nullptr) {
                Serial.println("Warning: Previous PSRAM buffer not null, freeing.");
                free(psram_audio_buffer);
                psram_audio_buffer = nullptr;
            }
            psram_audio_buffer = (uint8_t*)ps_malloc(expected_audio_length);

            if (psram_audio_buffer == nullptr) {
                Serial.printf("Error: Failed to allocate %u bytes in PSRAM for audio.\n", expected_audio_length);
                expected_audio_length = 0; 
                return;
            }
            current_audio_received_count = 0;
            data_idx = 4; 
        }

        if (psram_audio_buffer == nullptr) {
            Serial.println("Error: No PSRAM buffer allocated, discarding incoming audio data chunk.");
            return;
        }

        size_t remaining_data_in_chunk = data_len - data_idx;
        size_t space_left_in_buffer = expected_audio_length - current_audio_received_count;
        size_t bytes_to_copy = std::min(remaining_data_in_chunk, space_left_in_buffer);

        if (bytes_to_copy > 0) {
            memcpy(psram_audio_buffer + current_audio_received_count, data.data() + data_idx, bytes_to_copy);
            current_audio_received_count += bytes_to_copy;
        }
        
        Serial.printf("Received audio chunk. Total received: %u / %u bytes\n", current_audio_received_count, expected_audio_length);

        if (current_audio_received_count > expected_audio_length) {
             Serial.println("Error: Received more audio data than expected. Resetting.");
             if (psram_audio_buffer != nullptr) {
                free(psram_audio_buffer);
                psram_audio_buffer = nullptr;
             }
             expected_audio_length = 0;
             current_audio_received_count = 0;
             return;
        }

        if (current_audio_received_count == expected_audio_length && expected_audio_length > 0) {
            Serial.printf("Full audio data (%u bytes) received. Dispatching to audio task.\n", current_audio_received_count);
            
            AudioPlayData_t dataToPlay;
            dataToPlay.buffer = psram_audio_buffer; // Pass ownership of the buffer
            dataToPlay.length = current_audio_received_count;

            if (xQueueSend(audioQueue, &dataToPlay, pdMS_TO_TICKS(100)) != pdPASS) {
                Serial.println("Failed to send audio data to queue. Freeing buffer.");
                free(psram_audio_buffer); // Free it here if queue send fails
            }
            
            // Reset for next audio file, psram_audio_buffer ownership is now with the audio task or freed
            psram_audio_buffer = nullptr; 
            expected_audio_length = 0;
            current_audio_received_count = 0;
        }
    }

    void onDisconnect(NimBLEL2CAPChannel* channel) override {
        Serial.println("L2CAP disconnected");
        isReady = true;
        connected = false;
        BLEDevice::startAdvertising();
    }
};

// camera related below
#include <esp_camera.h>
// camera pins
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

#define LED_GPIO_NUM      21

void sendJpeg(NimBLEL2CAPChannel* channel, const uint8_t* jpeg_buf, size_t jpeg_len) {

    // std::vector<uint8_t> test_packet(100000, 0xCC); // 100 bytes of 0xCC 4935 = broken, 4934 = ok

    Serial.printf("jpeg_len: %u\n", jpeg_len);
    std::vector<uint8_t> packet;
    packet.reserve(4 + jpeg_len);

    packet.push_back(static_cast<uint8_t>(jpeg_len & 0xFF));
    packet.push_back(static_cast<uint8_t>((jpeg_len >> 8) & 0xFF));
    packet.push_back(static_cast<uint8_t>((jpeg_len >> 16) & 0xFF));
    packet.push_back(static_cast<uint8_t>((jpeg_len >> 24) & 0xFF));

    packet.insert(packet.end(), jpeg_buf, jpeg_buf + jpeg_len);

    int written = channel->write(packet);
    if (written < 0) {
        Serial.println("Failed to send data");
        return;
    }
    // doorBell();
}

// button
#define BUTTON_PIN 9

// Global instances
static L2CAPChannelCallbacks* l2capCb;
static NimBLEL2CAPChannel*     channel;

void setup() {

    // start serial communication
    Serial.begin(115200);
    delay(3000);

    pinMode(BUTTON_PIN, INPUT_PULLUP);

    audioQueue = xQueueCreate(5, sizeof(AudioPlayData_t)); // Queue for 5 audio jobs
    if (audioQueue == NULL) {
        Serial.println("Error creating audio queue");
        // Handle error
    }

    xTaskCreatePinnedToCore(
        audioPlayerTask,          // Task function
        "AudioPlayerTask",        // Name of the task
        8192,                     // Stack size in words (try 8192, then 10240 if needed)
        NULL,                     // Task input parameter
        5,                        // Priority of the task (adjust as needed)
        &audioTaskHandle,         // Task handle
        APP_CPU_NUM); // Or PRO_CPU_NUM, usually APP_CPU for applications

    if(audioTaskHandle == NULL){
        Serial.println("Failed to create AudioPlayerTask");
    } else {
        Serial.println("AudioPlayerTask created successfully");
    }
    
    // Camera and related initialization
    if (!psramInit()) {
        Serial.println("PSRAM init failed!");
        while (true) { vTaskDelay(pdMS_TO_TICKS(100)); }
    }
    Serial.printf("PSRAM Size: %u bytes\n", ESP.getPsramSize());

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
        .jpeg_quality   = 15,
        .fb_count       = 2,
        .fb_location    = CAMERA_FB_IN_PSRAM,
        .grab_mode      = CAMERA_GRAB_LATEST,
    };

    if (esp_camera_init(&config) != ESP_OK) {
        Serial.println("Camera init failed");
        while (true) { delay(10000); }
    }

    sensor_t* sensor = esp_camera_sensor_get();
    sensor->set_hmirror(sensor, 1);
    
    Serial.println("Camera initialized");

    Serial.printf("Starting L2CAP server [%u free] [%u min]\n",
                  esp_get_free_heap_size(), esp_get_minimum_free_heap_size());

    // BLE initialization
    BLEDevice::init("L2CAP-Server");
    BLEDevice::setMTU(BLE_ATT_MTU_MAX);

    // Create L2CAP CoC server
    auto cocServer = BLEDevice::createL2CAPServer();
    l2capCb = new L2CAPChannelCallbacks();
    channel = cocServer->createService(L2CAP_CHANNEL, L2CAP_MTU, l2capCb);

    // Create GATT server for service UUID
    auto server = BLEDevice::createServer();
    server->setCallbacks(new GATTCallbacks());
    server->advertiseOnDisconnect(true);

    auto service = server->createService(SERVICE_UUID);
    characteristic = service->createCharacteristic(
        CHARACTERISTIC_UUID,
        NIMBLE_PROPERTY::READ |
        NIMBLE_PROPERTY::NOTIFY
    );
    characteristic->createDescriptor("2902", NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);
    characteristic->setValue((uint16_t)L2CAP_CHANNEL);
    service->start();

    // Start advertising
    auto advertising = BLEDevice::getAdvertising();
    advertising->addServiceUUID(SERVICE_UUID);
    advertising->enableScanResponse(true);
    BLEDevice::startAdvertising();
    Serial.println("Waiting for connections...");
}

// function to send image
void sendImage() {
    doorBell();
    delay(50);
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
        Serial.println("Camera capture failed");
        return;
    }
    Serial.printf("Size of image: %u\n", fb->len);
    sendJpeg(channel, fb->buf, fb->len);
    esp_camera_fb_return(fb);
}

void loop() {

    // Button trigger to send image
    if (digitalRead(BUTTON_PIN) == LOW && isReady) {
        isReady = false;
        sendImage();
    }

    // Serial trigger to send image
    if (channel && l2capCb->connected && Serial.available() && isReady) {
        isReady = false;
        String cmd = Serial.readStringUntil('\n');
        cmd.trim();
        if (cmd.equalsIgnoreCase("send")) {
            sendImage();
        }
    }

    delay(50);
}
*/