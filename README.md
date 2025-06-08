This project allows an iPhone to communicate with a Seeed Studio XIAO ESP32S3 Sense over BLE to enable the ESP32S3 to play an audio description of images it captures.

### How to Use
Operation is straightforward assuming you have the app and the glasses module:
 - Open the iOS app
 - Turn on the glasses with the switch
 - Click "Connect" in the app
 - Press the button on the glasses
 - Listen to the audio

To upload the code to the ESP32S3, clone the repository, open the esp folder in PlatformIO, and click upload. The Swift code, which can be built in Xcode, is in the ios folder.

### General Considerations
 - ESP camera image resolution
 - Prompts for both API calls on iPhone
 - Model(s) used, reasoning effort, and image input detail level


### BLE Settings

#### Increase retries + add short delay between sends

In `NimBLEL2CAPChannel.cpp`:

```cpp
bool NimBLEL2CAPChannel::write(const std::vector<uint8_t>& bytes) {
    if (!this->channel) {
        NIMBLE_LOGW(LOG_TAG, "L2CAP Channel not open");
        return false;
    }

    struct ble_l2cap_chan_info info;
    ble_l2cap_get_chan_info(channel, &info);
    auto mtu = info.peer_coc_mtu < info.our_coc_mtu ? info.peer_coc_mtu : info.our_coc_mtu;

    auto start = bytes.begin();
    while (start != bytes.end()) {
        vTaskDelay(20);             // <-- ADD THIS LINE
        auto end = start + mtu < bytes.end() ? start + mtu : bytes.end();
        if (writeFragment(start, end) < 0) {
            return false;
        }
        start = end;
    }
    return true;
}
```

```cpp
// Retry
constexpr uint32_t RetryTimeout = 50;
constexpr int RetryCounter = 10;    // <-- change to 10
```

#### Adjust logging + MSYS buffers

In `nimconfig.h`:

```cpp
#define CONFIG_BT_NIMBLE_LOG_LEVEL 5
#define CONFIG_NIMBLE_CPP_LOG_LEVEL 5
#define CONFIG_BT_NIMBLE_MSYS1_BLOCK_COUNT 50
```