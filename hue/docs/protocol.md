# Philips Hue CLIP v2 protocol

Philips Hue bridge integration over the local CLIP v2 HTTPS API: mDNS discovery, link-button pairing, and per-light color updates.

---

## Overview

The bridge is discovered via mDNS (`_hue._tcp.local.`) and addressed over HTTPS on port 443. TLS uses Signify's Hue root CA (pinned in the manifest, `custom-ca` profile); the certificate identity is the bridge ID, checked against the certificate subject CN. Requests time out after at most 3000 ms and only GET, PUT, and POST are permitted.

The model is host-initiated request/response. Pairing posts to `/api` and, after the user presses the bridge link button, returns an application key (and an optional Entertainment client key). Every authenticated CLIP v2 request carries the application key in the `hue-application-key` header. The bridge never pushes data to the plugin.

---

## 1. Packet layout

All payloads are JSON over HTTPS. CLIP v2 resource paths are rooted at `/clip/v2/resource`.

### Pairing request - `POST /api`

```json
{"devicetype":"halod#desktop","generateclientkey":true}
```

Sent with `Content-Type: application/json` and no authentication header. The reply is an array; on success it contains a `success` object:

```json
[{"success":{"username":"<application key>","clientkey":"<entertainment key>"}}]
```

Before the link button is pressed the array carries an `error` object instead and no `username` appears.

### Light update - `PUT /clip/v2/resource/light/<id>`

Color on:

```json
{"on":{"on":true},"dimming":{"brightness":73.500},"color":{"xy":{"x":0.312700,"y":0.329000}}}
```

Black (off):

```json
{"on":{"on":false}}
```

`brightness` is a percentage (formatted to 3 decimals, minimum 1); `x` and `y` are CIE 1931 chromaticity coordinates formatted to 6 decimals.

### Resource reads

`GET /clip/v2/resource/bridge` and `GET /clip/v2/resource/light` return:

```json
{"errors":[],"data":[{"id":"<uuid>","metadata":{"name":"..."},"color":{...}}]}
```

Only the `data` array is consumed; a light entry needs `id`, is filtered on the presence of `color`, and `metadata.name` supplies the display name.

---

## 2. Functions

| Function | Request | Auth | Notes |
| --- | --- | --- | --- |
| `discover` | none (mDNS) | none | Reads `_hue._tcp.local.` results; `bridgeid` (or `bridgeId`) TXT record becomes the bridge ID and certificate identity |
| `pair` | `POST /api` | none | Link-button flow; see subsection |
| `validate` | `GET /clip/v2/resource/bridge` | app key | Fails unless HTTP 200 |
| `enumerate_controllers` | `GET /clip/v2/resource/light` | app key | Errors unless HTTP 200; one controller per color-capable light |
| `set_light_color` | `PUT /clip/v2/resource/light/<id>` | app key | Deduplicated and rate-limited; see subsection |

### Pairing sequence

1. The user presses the round link button on the bridge and starts pairing within 30 seconds.
2. `POST /api` with the pairing body from section 1.
3. If the reply body contains no `username`, pairing is pending: the user is told to press the button and retry.
4. On success the `username` is stored as `app_key` and, when present and non-empty, `clientkey` is stored as `client_key`. Both are secure config values.

An unpaired bridge (empty `app_key`) initializes as idle rather than failing; enumeration then returns no controllers.

### Color update sequence

Per light, keyed by the CLIP light id:

1. Skip the write if the RGB triple equals the last successfully written color, or if fewer than 100 ms have passed since the previous write (skipped frames are dropped, not queued).
2. If peak RGB is 0, send the off body. Otherwise convert RGB to xy (section 3), derive brightness from the peak channel, and send the color body.
3. Any status outside 200-299 raises an error; on success record the color and set the next allowed write time to now + 100 ms.

Both the effect path (`apply`, static color only) and the streaming path (`write_frame`, first RGB triple of the frame) funnel into this sequence.

---

## 3. Parameters

### Transport and auth

| Parameter | Value |
| --- | --- |
| Base origin | `https://<host>` (IPv6 literals are bracketed) |
| Default port | 443 |
| Auth header | `hue-application-key: <app_key>` on all CLIP v2 requests |
| TLS | Pinned Signify Hue root CA; identity = bridge ID vs subject CN |
| Request timeout | 3000 ms maximum |
| Per-light write interval | 100 ms minimum |

### Config keys

| Key | Meaning |
| --- | --- |
| `host` | Bridge address (mDNS-discovered or manual) |
| `port` | Bridge port |
| `bridge_id` | Certificate identity advertised during discovery |
| `app_key` | Application key from pairing (secure) |
| `client_key` | Entertainment client key from pairing (secure); reserved for future DTLS/UDP streaming |

### RGB to xy conversion

Each 0-255 channel is linearized with the sRGB transfer function:

```text
c = v / 255
linear(c) = c / 12.92                     if c <= 0.04045
linear(c) = ((c + 0.055) / 1.055) ^ 2.4   otherwise
```

then mapped to XYZ with the Wide RGB D65 matrix:

```text
X = 0.664511 r + 0.154324 g + 0.162028 b
Y = 0.283881 r + 0.668433 g + 0.047685 b
Z = 0.000088 r + 0.072310 g + 0.986039 b
x = X / (X + Y + Z),  y = Y / (X + Y + Z)   (0, 0 if the sum is 0)
```

Brightness is taken from the peak RGB channel: `max(1, peak / 255 * 100)` percent. Chromaticity and brightness are therefore independent: xy encodes hue and saturation, the peak channel encodes intensity.

---

## 4. Responses

| Request | Success | Failure handling |
| --- | --- | --- |
| `POST /api` | Body contains `"username"` (and optionally `"clientkey"`) | Missing `username` = link button not pressed yet; pairing stays pending |
| `GET /clip/v2/resource/bridge` | HTTP 200 | Any other status fails validation with the status code |
| `GET /clip/v2/resource/light` | HTTP 200 with `data` array | Any other status raises an error |
| `PUT /clip/v2/resource/light/<id>` | HTTP 2xx | Status outside 200-299 raises an error; the color is not recorded as written |

Light entries in `data` are used as follows: `id` becomes the controller key (controller id `hue_light_<id>`), `metadata.name` becomes the display name (fallback `Hue light <id>`), and entries without a `color` object are skipped because dimmable-only and color-temperature-only resources cannot satisfy the RGB contract.

---

## 5. Polling & notifications

None: all access is host-initiated request/response. The bridge is never polled on a timer; lights are enumerated on demand and color writes are pushed as state changes, throttled to one write per light per 100 ms.

---

## Notes

- IPv6 bridge addresses are wrapped in brackets when building the origin.
- Duplicate-color suppression compares the exact RGB triple against the last write that succeeded, so a failed update is retried on the next frame.
- Frames arriving inside a light's 100 ms window are dropped; the last color of a burst is not guaranteed to reach the bridge until a later frame repeats it.
- `client_key` is captured at pairing time alongside `app_key` so Entertainment streaming (DTLS/UDP) will not require re-pairing once a UDP transport exists.
