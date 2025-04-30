// main.cpp
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEL2CAPChannel.h>

// See the following for generating UUIDs:
// https://www.uuidgenerator.net/

#define SERVICE_UUID        "dcbc7255-1e9e-49a0-a360-b0430b6c6905"
#define CHARACTERISTIC_UUID "371a55c8-f251-4ad2-90b3-c7c195b049be"
#define L2CAP_CHANNEL        150
#define L2CAP_MTU            5000

class GATTCallbacks: public BLEServerCallbacks {
public:
    void onConnect(BLEServer* pServer, BLEConnInfo& info) {
        printf("GATT connection established\n");
        pServer->setDataLen(info.getConnHandle(), 251);
        BLEDevice::getServer()->updateConnParams(info.getConnHandle(), 12, 12, 0, 200);
    }

    void onDisconnect(BLEServer* pServer, BLEConnInfo& info) {
        printf("GATT disconnected, advertising again\n");
        // Resume advertising after disconnection
        pServer->getAdvertising()->start();
    }
};

class L2CAPChannelCallbacks: public BLEL2CAPChannelCallbacks {
public:
    bool connected = false;
    size_t numberOfReceivedBytes = 0;

    void onConnect(NimBLEL2CAPChannel* channel, uint16_t negotiatedMTU) {
        printf("L2CAP channel established (MTU %u)\n", negotiatedMTU);
        connected = true;
        numberOfReceivedBytes = 0;
    }

    void onRead(NimBLEL2CAPChannel* channel, std::vector<uint8_t>& data) {

        data.push_back('\0');
        const char* txt = reinterpret_cast<char*>(data.data());
        Serial.printf("\nReceived: %s\n", txt);

        data.pop_back();

        if (strcmp(txt, "Hi ESP32 (init ios)") == 0) {
            String str = "Hi iPhone (init ios)";
            std::vector<uint8_t> bytesToSend(str.begin(), str.end());
            bytesToSend.push_back('\0'); // Null-terminate the string
            
            bool ok = channel->write(bytesToSend);
            if(!ok) {
                Serial.println("Failed to send data back to client");
            }
        } else if (strcmp(txt, "Hi ESP32 (init esp)") == 0) {

        }
    }

    void onDisconnect(NimBLEL2CAPChannel* channel) {
        printf("L2CAP disconnected\n");
        connected = false;
        // After CoC disconnect, continue advertising for new connections
        BLEDevice::startAdvertising();
    }
};

extern "C" void app_main(void) {
    // Initialize serial
    Serial.begin(115200);
    delay(2000);

    printf("Starting L2CAP server [%u free] [%u min]\n", esp_get_free_heap_size(), esp_get_minimum_free_heap_size());

    BLEDevice::init("L2CAP-Server");
    BLEDevice::setMTU(BLE_ATT_MTU_MAX);

    auto cocServer = BLEDevice::createL2CAPServer();
    auto l2capCb = new L2CAPChannelCallbacks();
    auto channel = cocServer->createService(L2CAP_CHANNEL, L2CAP_MTU, l2capCb);

    auto server = BLEDevice::createServer();
    server->setCallbacks(new GATTCallbacks());
    server->advertiseOnDisconnect(true);

    auto service = server->createService(SERVICE_UUID);
    auto characteristic = service->createCharacteristic(CHARACTERISTIC_UUID, NIMBLE_PROPERTY::READ);
    characteristic->setValue((uint16_t)L2CAP_CHANNEL);
    service->start();

    auto advertising = BLEDevice::getAdvertising();
    advertising->addServiceUUID(SERVICE_UUID);
    advertising->enableScanResponse(true);
    BLEDevice::startAdvertising();
    printf("Waiting for connections...\n");

    while (true) {

        if (Serial.available()) {
            String cmd = Serial.readStringUntil('\n');
            cmd.trim();
            if (cmd.equalsIgnoreCase("send")) {
                String str = "Hi iPhone (init esp)";
                std::vector<uint8_t> bytesToSend(str.begin(), str.end());
                bytesToSend.push_back('\0'); // Null-terminate the string
                
                bool ok = channel->write(bytesToSend);
                if(!ok) {
                    Serial.println("Failed to send data back to client");
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(100));
    }
}