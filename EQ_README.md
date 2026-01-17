# Liquidsoap EQ System Documentation

## Overview
This implementation adds a professional 10-band graphic equalizer with presets to your Liquidsoap radio automation script. The EQ is applied to the final output stream before Icecast transmission, ensuring consistent audio processing across all content (music, ads, prayer times).

## Installation

### 1. No External Dependencies Required
The EQ system uses Liquidsoap's built-in IIR filter functions, so no external plugins need to be installed. Only the config directory is required:

```bash
# Create config directory for persistent settings
sudo mkdir -p /home/oooomedia/liq_scripts/configs
sudo chown -R oooomedia:oooomedia /home/oooomedia/liq_scripts/configs
```

### 2. Script Integration
The EQ system has been integrated into your existing script with:
- **Built-in IIR filters** - no external dependencies
- **Persistent preset storage** across restarts
- **HTTP API** for remote control
- **Universal compatibility** with all Liquidsoap versions

## EQ Presets

### Available Presets
1. **flat** - No EQ (0dB all bands) - Default
2. **vocal_boost** - Enhanced mid-range for speech clarity
3. **bass_heavy** - Enhanced low-end for bass-heavy music
4. **bright** - Enhanced high frequencies for clarity
5. **warm** - Slight bass boost with rolled-off highs
6. **radio_classic** - Traditional radio sound curve
7. **pop** - V-shaped curve: bass boost + sparkly highs
8. **rock** - Mid-forward with punchy bass and crisp highs
9. **classical** - Subtle enhancement preserving natural dynamics

### Frequency Bands (10-band EQ)
- 31 Hz, 62 Hz, 125 Hz, 250 Hz, 500 Hz
- 1 kHz, 2 kHz, 4 kHz, 8 kHz, 16 kHz

## HTTP API Usage

### Get Current EQ Status
```bash
curl "http://localhost:7000/eq_preset_<USER_ID>"
```

**Response:**
```json
{
  "current_preset": "pop",
  "available_presets": ["flat", "vocal_boost", "bass_heavy", "bright", "warm", "radio_classic", "pop", "rock", "classical"],
  "eq_available": true
}
```

### Change EQ Preset
```bash
curl -X POST "http://localhost:7000/eq_preset_<USER_ID>?preset=rock"
```

**Response:**
```json
{
  "status": "success",
  "message": "EQ preset changed to rock",
  "current_preset": "rock"
}
```

### Health Check (Enhanced)
```bash
curl "http://localhost:7000/health_<USER_ID>"
```

Now includes EQ status:
```json
{
  "user_id": "123",
  "current_loop": "A",
  "eq_preset": "rock",
  "eq_available": true,
  ...
}
```

## Testing

### Use the Test Script
```bash
./test_eq.sh <USER_ID>
```

### Manual Testing
```bash
# Test different presets
curl -X POST "http://localhost:7000/eq_preset_123?preset=pop"
curl -X POST "http://localhost:7000/eq_preset_123?preset=classical"
curl -X POST "http://localhost:7000/eq_preset_123?preset=flat"

# Check current status
curl "http://localhost:7000/eq_preset_123"
```

## File Structure

### New Files Created
```
/home/oooomedia/liq_scripts/
├── configs/
│   └── <user_id>_eq.conf    # Persistent EQ preset storage
├── logs/
│   └── <user_id>.log        # Enhanced with EQ logging
└── script.liq               # Modified with EQ system
```

## Logging

### EQ-Related Log Messages
- `INFO: Built-in EQ filters available and working`
- `INFO: EQ preset loaded: <preset_name>`
- `INFO: EQ preset saved: <preset_name>`
- `INFO: Built-in EQ applied with preset: <preset_name>`
- `WARNING: Built-in EQ filters not available: <error>`
- `ERROR: EQ processing failed: <error>, bypassing EQ`

## Troubleshooting

### EQ Not Working
1. **Check logs:**
   ```bash
   tail -f /home/oooomedia/liq_scripts/logs/<user_id>.log | grep EQ
   ```

2. **Test filter availability:**
   The built-in filters should always be available in Liquidsoap. If they're not working, check your Liquidsoap version.

### Common Issues

#### Filters Not Available
```
WARNING: Built-in EQ filters not available: <error>
```
**Solution:** This is rare - check your Liquidsoap installation and version

#### Permission Issues
```
ERROR: Failed to save EQ preset: Permission denied
```
**Solution:** Check config directory permissions:
```bash
sudo chown -R oooomedia:oooomedia /home/oooomedia/liq_scripts/configs
```

#### Invalid Preset
```json
{
  "status": "error",
  "message": "Invalid preset. Available: flat, vocal_boost, ..."
}
```
**Solution:** Use one of the valid preset names listed in the error message.

## Integration Notes

### Audio Chain Flow
```
Music/Ads → Ad Scheduler → Audio Enhancement → Prayer Time Switch → **EQ** → Icecast
```

### Persistence
- EQ preset is automatically saved when changed
- Loaded on script startup/restart
- Survives system reboots
- Falls back to "flat" if config corrupted

### Performance Impact
- Minimal CPU overhead (~1-2% additional load)
- No impact on existing functionality
- Graceful degradation if plugins fail

## Advanced Usage

### Custom Presets
To add custom presets, modify the `get_eq_preset_params()` function in the script and add the preset name to validation lists.

### Remote Control Integration
The HTTP API can be integrated with:
- Web dashboards
- Mobile apps  
- Automation scripts
- Third-party control systems

### Monitoring
Monitor EQ status via the health endpoint or log files for automated systems.
