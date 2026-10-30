# Agent guidance

## Overview

This repository contains services for a Raspberry Pi smart home setup:
- **home-assistant-amb**: Main Home Assistant instance with custom components
- **frigate**: Video surveillance
- **pi-hole**: Network-wide ad blocker
- **zigbee2mqtt-amb**: Zigbee device integration via MQTT
- **teslamate**: Tesla vehicle tracking
- **samba**: Containerized file sharing and Time Machine backups on pi501 (see `samba/README.md`)
- **duux-emqx**: Dedicated EMQX broker for Duux fan local control (LAN-exposed TLS on port 443)

## Common Commands

### Home Assistant (Primary Service)

The home-assistant-amb service is the most actively developed component. Commands use `just`:

```bash
cd home-assistant-amb
just build              # Build Docker image with custom components
just test               # Validate Home Assistant configuration (requires Docker)
```

The build process creates a custom Docker image based on `ghcr.io/home-assistant/home-assistant:2026.7.0` with baked-in custom components:
- **adaptive-lighting**: Dynamic light color/brightness adjustment
- **duux_fan_local**: Local control of Duux fans via the `duux-emqx/` broker

### Pre-commit Hooks

```bash
pre-commit run --all-files    # Run YAML validation and formatting checks
```

Note: Pre-commit excludes Home Assistant blueprint files and configuration.yaml which use special YAML syntax.

## Architecture

### Home Assistant Configuration Structure

Home Assistant config uses a split configuration model (see `home-assistant-amb/config/configuration.yaml`):

- **Directories merged as lists** (`!include_dir_merge_list`):
  - `automation/`: Individual automation YAML files
  - `sensor/`: Sensor definitions
  - `template/`: Template sensors and binary sensors
    - `climate_floor_averages.yaml`: Floor-average temperature and humidity sensors
      (`sensor.climate_{ground,first,second}_floor_{temperature,humidity}`).
      **Attic is intentionally excluded from the second-floor average** — the attic is
      normally closed off (fold-out stairs access only) and its temperature deviates
      significantly from the lived-in second-floor rooms. Do not add it back.

- **Individual files included** (`!include`):
  - `input_boolean.yaml`, `input_datetime.yaml`, `input_number.yaml`: User inputs
  - `lovelace.yaml`: Dashboard index — uses `resource_mode: yaml` and registers dashboards from `dashboard/*.yaml` (overview, climate, lights, power)
  - `logbook.yaml`: Logbook configuration
  - `script.yaml`: Scripts
  - `binary_sensor.yaml`: Binary sensor definitions
  - `adaptive_lighting.yaml`: Adaptive lighting configurations for each light/room
  - `mqtt.yaml`: Manually-defined MQTT entities (currently: TeslaMate car sensors). The MQTT broker connection itself is a separate UI-managed config entry, not YAML.

### Dashboard Conventions

Lovelace dashboards (`dashboard/*.yaml`) follow these conventions:

- **Titles** (`heading_style: title`) = section names. They are never links and need no corresponding dashboard page — they organize local content within a view.
- **Subheaders** (`heading_style: subtitle`) = view names. Subheaders tap-link directly to that view's page.
- **View order** in a sub-dashboard (Power, Lights, Climate) must match the order the corresponding subheaders appear on the Overview dashboard, so the sidebar tab order mirrors the overview.

### Energy Dashboard

The built-in Home Assistant Energy dashboard (grid source, "Individual devices" list, and the "Energy flow" Sankey chart) is configured entirely via **Settings → Dashboards → Energy** in the UI and stored in `.storage/energy` — it is not represented anywhere in this repo's YAML. To make a new sensor appear in the Energy flow chart, first deploy the entity (as YAML, via the normal flow), then manually add it as an Individual Device in that UI. Energy-tracking sensors should have `device_class: energy`, a `kWh`/`Wh`/`MWh` unit, and a `total` or `total_increasing` state class (see e.g. `sensor.tesla_energy_charged_at_home`, built from the `integration` platform in `config/sensor/tesla_energy.yaml`).

### Zigbee2MQTT Device Renames

The Z2M web UI "Rename device" dialog has an **"Update Home Assistant entity ID"** checkbox (checked by default). When checked, renaming the `friendly_name` republishes MQTT discovery with the new `object_id` and HA updates the existing entity's `entity_id` to match — no separate HA-side entity rename needed. (Z2M does *not* key HA entities by IEEE address with a sticky `entity_id`; the checkbox drives the update.)

When deploying YAML that references the new `entity_id`s, do the Z2M rename (box ticked) first so entities exist under the new ids, then deploy/reload the HA config. Verify afterward in Developer Tools → States (HA may append `_2` if an orphan collides).

### Custom Components Symlink Pattern

The Dockerfile installs custom components to `/custom_components`. The mounted config directory contains a symlink `custom_components -> /custom_components`. This allows custom components to be baked into the Docker image while the config directory is mounted at runtime.

### Key Home Assistant Concepts Used

**Adaptive Lighting**: Each light/room has a configuration in `adaptive_lighting.yaml` with settings like:
- `min_brightness`/`max_brightness`: Brightness range
- `min_color_temp`/`max_color_temp`: Color temperature range (Kelvin)
- `sleep_brightness`/`sleep_transition`: Sleep mode behavior
- `max_sunset_time`: Override sunset time for bedrooms

**Blueprints**: Custom automation blueprints live in `config/blueprints/automation/custom/`. Key ones:
- `light_motion_activated_dark_aware.yaml` / `light_motion_activated_dark_aware_script.yaml`: Motion-activated lights with dark awareness
- `hue_dimmer_switch.yaml`, `hue_tap_dial.yaml`, `hue_wall_switch.yaml`, `friends_of_hue_switch.yaml`: Hue switch/dial handlers
- `heating_needed_alert.yaml`: Heating alert logic
- `water_leak.yaml`: Water leak notifications
- `light_disco.yaml`, `light_disco_single.yaml`: Disco light effects

**Motion-Activated Lights**: Custom blueprint `light_motion_activated_dark_aware.yaml` implements:
- Turn on at full adaptive brightness when motion detected
- When no motion and dark: dim to lower percentage instead of turning off
- When no motion and bright/sleep mode: turn off completely
- Respects device-specific no-motion delays

**Presence Detection**: Multi-level presence system (see `template/presence.yaml`):
- Individual sensor timers: Door contacts, motion sensors trigger "recent" binary sensors with auto-off
- Floor-level presence: `Presence Ground Floor` (20 min delay), `Presence First Floor` (15 min), `Presence Second Floor` (5 min)
- House-level presence: `Presence House` combines person locations + floor presence
- Prevents lights from turning off prematurely when moving between rooms

**Dark Awareness**: Binary sensors in `template/dark.yaml`:
- `Sufficiently Dark For Indoor Lights`: Illuminance < threshold (uses `motion_garden_illuminance_filtered`)
- `Sufficiently Dark For Outdoor Lights`: Illuminance < lower threshold

### CI/CD

GitHub Actions workflow validates Home Assistant config on every push to `home-assistant-amb/**`:
1. Builds Docker image
2. Runs `just test` (Home Assistant's `hass --script check_config`)

## Making Changes

When modifying Home Assistant configuration:

1. Edit YAML files in `home-assistant-amb/config/`
2. Run `just test` to validate configuration locally. If there are no problems, there is no output. It may seem like it didn't work. Make sure the return code is not an error code.
3. Always run `just test` immediately before committing. Do not commit or push if it fails.
4. Create a branch, commit and push (CI will validate again)
4. To verify on live Home Assistant
    - If the image is unchanged, instruct the user to checkout the branch on Raspberry pi (or simply pull if that has already happened and we're iterating), and reload configuration or restart via UI
    - If the image is changed (either the `Dockerfile` itself or the tag in `docker-compose.yaml`), instruct the user to run `docker compose up -d --build` on the Raspberry pi in the `home-assistant-amb` directory.

When adding/removing adaptive lighting configs, update references in:
- `automation/light_adaptive_toggle.yaml`
- `automation/sleep_mode.yaml`
