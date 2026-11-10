# Wire protocol (v1, draft)

The Mac connects to the TV over TCP. Both directions carry messages using the same framing.

- **Port:** `48100` (TCP)
- **Bonjour service (Phase 5):** `_tvextend._tcp`
- **Byte order:** big-endian

## Message framing

Every message has a 16-byte header followed by `length` bytes of payload.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 2 | `magic` | `0x5458` ("TX") |
| 2 | 1 | `type` | see below |
| 3 | 1 | `flags` | bit 0 = keyframe |
| 4 | 4 | `length` | payload size in bytes |
| 8 | 8 | `timestamp_us` | sender's clock, microseconds |

## Message types

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | `HELLO` | Mac → TV | JSON: `{"version":1,"codec":"avc","width":1920,"height":1080,"fps":60}` |
| 0x02 | `HELLO_ACK` | TV → Mac | JSON: `{"version":1,"name":"Living Room TV","maxWidth":1920,"maxHeight":1080,"codecs":["avc","hevc"]}` |
| 0x10 | `CODEC_CONFIG` | Mac → TV | SPS + PPS (HEVC also sends VPS), Annex B with start codes |
| 0x11 | `FRAME` | Mac → TV | One encoded access unit, Annex B |
| 0x20 | `REQUEST_KEYFRAME` | TV → Mac | empty (sent after decoder errors or a reconnect) |
| 0x30 | `PING` | either | empty; the other side echoes `timestamp_us` back in a `PONG` |
| 0x31 | `PONG` | either | empty |
| 0x7F | `BYE` | either | empty; closing cleanly |

## Connection flow

1. Mac connects and sends `HELLO`.
2. TV replies with `HELLO_ACK`. If the version or codec isn't supported, the TV sends `BYE` instead.
3. Mac sends `CODEC_CONFIG`, then a keyframe `FRAME`, then delta frames as the screen changes.
4. Mac sends `PING` about once a second to measure round-trip time; a missed run of pings means
   the connection is dead.
