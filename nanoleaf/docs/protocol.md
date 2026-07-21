<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: HaloDaemon
-->

# Nanoleaf OpenAPI (v1) protocol

Nanoleaf light-panel controller protocol: local HTTP OpenAPI v1 for pairing, state, and layout, plus the UDP external-control v2 stream for real-time per-panel color.

**Credits:** protocol per the official [Nanoleaf OpenAPI documentation](https://nanoleaf.atlassian.net/wiki/spaces/nlapid/pages/2789310530/Nanoleaf+Light+Panels+Open+API+Documentation).

---

## Overview

The controller exposes a local HTTP API on port `16021`. Every authenticated request is `http://<host>:16021/api/v1/<token><suffix>`, where `<token>` is the pairing token held in secure config. Pairing (`POST /api/v1/new` while the power button is held) returns the token.

Per-panel color streams over UDP external control v2: one HTTP write arms the mode, then the host pushes binary datagrams to the streaming port (`60222`). When UDP is unavailable, an HTTP `static` effect write sets each panel instead; with no panel layout at all, the whole controller is driven as a single logical LED through the global HSV `/state` path. All traffic is host-initiated.

---

## 1. Packet layout

### UDP v2 stream datagram

Big-endian binary, sent to `stream_host:stream_port` (default `60222`):

```text
nPanels : u16
per panel:
  panelId        : u16
  R, G, B, W     : u8 each
  transitionTime : u16   (units of 0.1 s)
```

One entry per declared LED, in declared LED order, with `W = 0` and `transitionTime = 1` (0.1 s). Compared to v1, the v2 layout widens `nPanels`, `panelId`, and `transitionTime` from 1 to 2 bytes and drops the per-panel `nFrames` field.

### HTTP payloads (JSON unless noted)

Arm ext-control, `PUT .../effects`:

```json
{ "write": { "command": "display", "animType": "extControl", "extControlVersion": "v2" } }
```

Static per-panel write, `PUT .../effects`:

```json
{ "write": { "command": "display", "animType": "static",
             "animData": "3 100 1 10 20 30 0 1 101 1 40 50 60 0 1 102 1 70 80 90 0 1",
             "loop": false, "palette": [] } }
```

`animData` is a space-separated integer list: `numPanels ( panelId numFrames R G B W transitionTime )*`, one frame per panel (`numFrames = 1`, `W = 0`, `transitionTime = 1`).

Global HSV state, `PUT .../state`:

```json
{ "on": { "value": true }, "hue": { "value": 120 }, "sat": { "value": 100 }, "brightness": { "value": 80 } }
```

Pairing, `POST /api/v1/new` (no token, empty body); reply carries `auth_token`.

---

## 2. Functions

| Function | Request | Notes |
| --- | --- | --- |
| `pair` | `POST /api/v1/new` | Only succeeds while the controller is in pairing mode; extracts `auth_token` from the reply |
| `validate` | `GET /api/v1/<token>/` | Expects HTTP 200 |
| get controller info / layout | `GET /api/v1/<token>/` | Full state including `panelLayout` (layout also at `.../panelLayout/layout`) |
| power on | `PUT .../state` with `{"on":{"value":true}}` | Issued at initialize so later frames take effect |
| arm ext-control | `PUT .../effects` with the extControl body | Once per session; controller then consumes UDP stream datagrams |
| stream frame | UDP v2 datagram | One datagram per distinct frame |
| static write | `PUT .../effects` with the `static` body | HTTP fallback for per-panel color |
| global color | `PUT .../state` with on/hue/sat/brightness | Single-LED fallback and static mode without layout |

### Panel topology

`positionData[]` in the layout is the source of truth: one entry per physical panel with a stable `panelId` and absolute `x`/`y` centre coordinates in millimetres, `y` increasing upward. The plugin declares one LED per panel (`led_count = numPanels`, `topology = "grid"`), in `positionData` order. Coordinates are normalized to `[0,1]` per axis (min/max over all panels) and `y` is flipped so the layout matches the UI's top-to-bottom axis. Panel ids are cached in the same order so frames map back to the right panel. When `panelLayout` is absent, the plugin falls back to a single logical LED driven through `/state`.

### Streaming sequence

1. Arm ext-control once over HTTP (cached; retried until a 2xx reply).
2. For each distinct frame, build and send one v2 datagram with colors taken from `write_frame`'s flat byte buffer or the `per_led` apply map. Identical frames are deduped; distinct frames stream every engine tick with no HTTP rate cap.
3. If UDP is unavailable, fall back to the HTTP `static` write, rate-limited to one write per 100 ms and deduped, matching the `/state` path.

---

## 3. Parameters

| Parameter | Value | Meaning |
| --- | --- | --- |
| HTTP port | `16021` | OpenAPI v1 |
| UDP stream port | `60222` | External control v2 |
| `hue` | 0-359 | HSV hue, degrees |
| `sat` | 0-100 | HSV saturation, percent |
| `brightness` | 0-100 | HSV value, percent |
| `W` | 0 | White channel, unused |
| `transitionTime` | 1 (0.1 s) | Blend time between frames, both in datagrams and `animData` |
| HTTP write rate limit | 100 ms | Applies to `/state` and the static-effect fallback |
| `extControlVersion` | `"v2"` | Selects the 2-byte-field datagram layout |

Colors are 8-bit RGB; the global `/state` path converts RGB to HSV (hue rounded to whole degrees, saturation and value as whole percent).

---

## 4. Responses

### Pairing reply

`POST /api/v1/new` returns 2xx with a JSON body containing `auth_token` when the controller is in pairing mode; a non-2xx status means pairing mode is not active yet.

### Controller info

`GET /api/v1/<token>/` returns 200 with the full controller state:

```json
{
  "name": "Shapes",
  "panelLayout": {
    "layout": {
      "numPanels": 3,
      "sideLength": 150,
      "positionData": [
        { "panelId": 100, "x": 0,   "y": 0,   "o": 0,  "shapeType": 12 },
        { "panelId": 101, "x": 100, "y": 0,   "o": 0,  "shapeType": 12 },
        { "panelId": 102, "x": 50,  "y": 100, "o": 60, "shapeType": 12 }
      ]
    }
  }
}
```

### Writes

State and effect `PUT`s are judged by HTTP status only (2xx = accepted). UDP datagrams are fire-and-forget: the controller never replies on the stream socket.

---

## 5. Polling & notifications

None: all access is host-initiated. The controller sends no unsolicited traffic; the host pushes frames on demand and there is no periodic status read. Discovery uses mDNS (`_nanoleaf._tcp.local.`) and SSDP (`nanoleaf_aurora:light`).

---

## Notes

- `transitionTime` is fixed at 1 (0.1 s) for a light blend between streamed frames; set it to 0 for hard snaps if the firmware prefers instant transitions.
- Official guidance (verified against the OpenAPI docs): external control can only be activated from display mode, and updates should not exceed roughly 10 per second. The UDP path currently streams every distinct engine tick, faster than that recommendation.
- The documented v2 datagram layout and port were verified against public Nanoleaf OpenAPI sources; no contradictions were found.
