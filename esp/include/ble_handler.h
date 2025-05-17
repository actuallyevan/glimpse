#ifndef BLE_HANDLER_H
#define BLE_HANDLER_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEL2CAPChannel.h>
#include <vector>

class L2CAPChannelCallbacks;

extern NimBLECharacteristic* gatt_characteristic;
extern L2CAPChannelCallbacks* l2cap_callbacks;
extern NimBLEL2CAPChannel* active_l2cap_channel;

extern volatile bool isReady;

class GATTCallbacks : public NimBLEServerCallbacks {
public:
    void onConnect(BLEServer* pServer, BLEConnInfo& info);
    void onDisconnect(BLEServer* pServer, BLEConnInfo& info);
};

class L2CAPChannelCallbacks : public NimBLEL2CAPChannelCallbacks {
public:
    bool connected = false;
    
    // variables for audio data handling
    uint8_t* psram_audio_buffer = nullptr;
    size_t expected_audio_length = 0;
    size_t current_audio_received_count = 0;
    size_t last_logged_audio_byte_count;

    void onConnect(NimBLEL2CAPChannel* channel, uint16_t negotiatedMTU);
    void onRead(NimBLEL2CAPChannel* channel, std::vector<uint8_t>& data);
    void onDisconnect(NimBLEL2CAPChannel* channel);
};

void ble_system_init();

// Sends notifications to wake up iOS app/keep it alive
void ble_keep_alive();

void ble_send_jpeg_data(const uint8_t* jpeg_buf, size_t jpeg_len);

#endif