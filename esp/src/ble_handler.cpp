#include "ble_handler.h"
#include "audio_handler.h"
#include "config.h"

NimBLECharacteristic *gatt_characteristic = nullptr;
L2CAPChannelCallbacks *l2cap_callbacks = nullptr;
NimBLEL2CAPChannel *active_l2cap_channel = nullptr;

void GATTCallbacks::onConnect(NimBLEServer *pServer, NimBLEConnInfo &info) {
  LOG_PRINTLN("[INFO]  GATT connected");

  // these are optimal settings for iOS L2CAP for maximum throughput
  pServer->setDataLen(info.getConnHandle(), 251);
  NimBLEDevice::getServer()->updateConnParams(info.getConnHandle(), 12, 12, 0, 200);
}

void GATTCallbacks::onDisconnect(NimBLEServer *pServer, NimBLEConnInfo &info) {
  LOG_PRINTLN("[INFO]  GATT disconnected");
}

void L2CAPChannelCallbacks::onConnect(NimBLEL2CAPChannel *client_channel, uint16_t negotiatedMTU) {
  LOG_PRINTF("[INFO]  L2CAP channel established (MTU %u)\n", negotiatedMTU);
  connected = true;
  active_l2cap_channel = client_channel; // store active channel

  NimBLEDevice::stopAdvertising(); // stop advertising when L2CAP connected

  // Reset audio receiving state
  expected_audio_length = 0;
  current_audio_received_count = 0;
  if (psram_audio_buffer) {
    free(psram_audio_buffer);
    psram_audio_buffer = nullptr;
  }
}

void L2CAPChannelCallbacks::onRead(NimBLEL2CAPChannel *client_channel, std::vector<uint8_t> &data) {
  if (data.empty()) {
    return;
  }

  size_t data_idx = 0;
  size_t data_len = data.size();

  if (expected_audio_length == 0) { // Start of a new audio file
    if (data_len < 4) {
      LOG_PRINTLN("[ERROR]  File too short for length header");
      return;
    }

    expected_audio_length = static_cast<size_t>(data[0]) | (static_cast<size_t>(data[1]) << 8) |
                            (static_cast<size_t>(data[2]) << 16) | (static_cast<size_t>(data[3]) << 24);

    ble_keep_alive(); // Notify to keep iOS awake during audio transfer

    LOG_PRINTF("[INFO]  Incoming audio data of size %u\n", expected_audio_length);

    if (expected_audio_length == 0) {
      LOG_PRINTLN("[ERROR]  Audio data zero length, ignoring");
      return;
    }

    if (psram_audio_buffer != nullptr) {
      LOG_PRINTLN("[ERROR]  Previous PSRAM buffer not null, freeing");
      free(psram_audio_buffer);
      psram_audio_buffer = nullptr;
    }
    psram_audio_buffer = (uint8_t *)ps_malloc(expected_audio_length);

    if (psram_audio_buffer == nullptr) {
      LOG_PRINTF("[ERROR]  Failed to allocate %u bytes in PSRAM for audio\n", expected_audio_length);
      expected_audio_length = 0;
      return;
    }
    current_audio_received_count = 0;
    data_idx = 4; // Skip the 4-byte length header
  }

  if (psram_audio_buffer == nullptr) {
    LOG_PRINTLN("[ERROR]  No PSRAM buffer allocated, discarding incoming audio data chunk");
    return;
  }

  size_t remaining_data_in_chunk = data_len - data_idx;
  size_t space_left_in_buffer = expected_audio_length - current_audio_received_count;
  size_t bytes_to_copy = std::min(remaining_data_in_chunk, space_left_in_buffer);

  if (bytes_to_copy > 0) {
    memcpy(psram_audio_buffer + current_audio_received_count, data.data() + data_idx, bytes_to_copy);
    current_audio_received_count += bytes_to_copy;
  }

  if (current_audio_received_count > expected_audio_length) {
    LOG_PRINTLN("[ERROR]  Received more audio data than expected, resetting");
    if (psram_audio_buffer != nullptr) {
      free(psram_audio_buffer);
      psram_audio_buffer = nullptr;
    }
    expected_audio_length = 0;
    current_audio_received_count = 0;
    return;
  }

  if (current_audio_received_count == expected_audio_length && expected_audio_length > 0) {
    LOG_PRINTF("[INFO]  Full audio data (%u bytes) received, sent to audio task\n", current_audio_received_count);

    // Pass ownership of psram_audio_buffer to audio task via queue
    if (!queue_audio_data_for_playback(psram_audio_buffer, current_audio_received_count)) {
      // Buffer was freed by queue_audio_data_for_playback on failure
      LOG_PRINTLN("[ERROR]  Failed to queue audio data playback");
    }

    psram_audio_buffer = nullptr;
    expected_audio_length = 0;
    current_audio_received_count = 0;
  }
}

void L2CAPChannelCallbacks::onDisconnect(NimBLEL2CAPChannel *channel) {
  connected = false;
  active_l2cap_channel = nullptr;

  if (psram_audio_buffer) {
    free(psram_audio_buffer);
    psram_audio_buffer = nullptr;
    LOG_PRINTLN("[INFO]  Freed PSRAM audio buffer");
  }
  expected_audio_length = 0;
  current_audio_received_count = 0;

  audio_system_reset_playback_state();
  isReady = true;
  LOG_PRINTLN("[INFO]  L2CAP disconnected");
}

void ble_system_init() {
  LOG_PRINTLN("[INFO]  Starting L2CAP server");

  NimBLEDevice::init("Glimpse Glass");
  NimBLEDevice::setMTU(BLE_ATT_MTU_MAX);

  auto cocServer = NimBLEDevice::createL2CAPServer();
  l2cap_callbacks = new L2CAPChannelCallbacks();

  cocServer->createService(L2CAP_PSM, L2CAP_MTU, l2cap_callbacks);

  auto server = NimBLEDevice::createServer();
  server->setCallbacks(new GATTCallbacks());
  server->advertiseOnDisconnect(true);

  auto service = server->createService(SERVICE_UUID);
  gatt_characteristic =
      service->createCharacteristic(CHARACTERISTIC_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

  uint16_t psm_val = L2CAP_PSM;
  gatt_characteristic->setValue((uint8_t)1); // this characteristic is purely for notification to wake iOS
  service->start();

  auto advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->enableScanResponse(true);
  NimBLEDevice::startAdvertising();
  LOG_PRINTLN("[INFO]  Waiting for BLE connection...");
}

// This function wakes up iOS app for processing using notification
void ble_keep_alive() {
  if (gatt_characteristic) {
    LOG_PRINTLN("[INFO]  Keep alive notification sent");
    gatt_characteristic->notify();
  }
}

void ble_send_jpeg_data(const uint8_t *jpeg_buf, size_t jpeg_len) {
  if (!active_l2cap_channel || !l2cap_callbacks || !l2cap_callbacks->connected) {
    LOG_PRINTLN("[ERROR]  Cannot send image: L2CAP not connected or channel not available");
    return;
  }

  LOG_PRINTF("[INFO]  Sending image data of size %u\n", jpeg_len);
  std::vector<uint8_t> packet;
  packet.reserve(4 + jpeg_len); // 4 bytes for length header + JPEG data

  // Prepend 4-byte length header
  packet.push_back(static_cast<uint8_t>(jpeg_len & 0xFF));
  packet.push_back(static_cast<uint8_t>((jpeg_len >> 8) & 0xFF));
  packet.push_back(static_cast<uint8_t>((jpeg_len >> 16) & 0xFF));
  packet.push_back(static_cast<uint8_t>((jpeg_len >> 24) & 0xFF));

  // Append JPEG data
  packet.insert(packet.end(), jpeg_buf, jpeg_buf + jpeg_len);

  int written = active_l2cap_channel->write(packet);
  if (written < 0) {
    LOG_PRINTLN("[ERROR]  Failed to send image over L2CAP");
  } else {
    LOG_PRINTLN("[INFO]  Image sent");
  }
}