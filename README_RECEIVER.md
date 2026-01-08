# ROSHI Receiver Setup Guide

This receiver receives video and metadata files from the ROSHI iOS app over LAN.

## Quick Start

### Option 1: Using the setup script (Recommended)

```bash
./setup_receiver.sh
python3 receiver.py
```

### Option 2: Manual setup

1. Install Python 3 (3.7 or later)

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Run the receiver:
```bash
python3 receiver.py
```

## Usage

### Basic usage (default port 50000):
```bash
python3 receiver.py
```

### With custom port:
```bash
python3 receiver.py --port 8080
```

### With custom output directory:
```bash
python3 receiver.py --output-dir /path/to/save/files
```

### Combined options:
```bash
python3 receiver.py --port 8080 --output-dir ~/roshi_recordings
```

## How it works

1. The receiver advertises itself on the local network using Bonjour/mDNS
2. The iOS app discovers the receiver automatically
3. When a recording finishes, the app sends:
   - Video file (`.mp4` format)
   - Metadata file (`.json` format with AprilTag detections and camera intrinsics)
4. Files are saved with timestamps:
   - `video_YYYYMMDD_HHMMSS.mp4`
   - `metadata_YYYYMMDD_HHMMSS.json`

## Requirements

- Python 3.7 or later
- `zeroconf` library (for Bonjour/mDNS)
- Both devices on the same local network

## Troubleshooting

### Receiver not found by iOS app
- Make sure both devices are on the same Wi-Fi network
- Check firewall settings (may need to allow Python/port)
- Try specifying a port explicitly: `python3 receiver.py --port 8080`

### Connection timeout
- Check that the port is not blocked by firewall
- Ensure both devices can reach each other on the network

### Files not saving
- Check write permissions for the output directory
- Verify the output directory path is correct

## Output Format

### Video files
- Format: H.264 encoded MP4 files
- Resolution: 720p (1280x720) by default
- FPS: 30 fps

### Metadata files
JSON format containing:
- Frame index
- UTC timestamp (ISO 8601)
- Timestamp in seconds
- Camera intrinsics matrix (3x3) for each frame
- AprilTag detections for each frame:
  - Tag ID
  - Center and corner positions
  - 3D position and rotation
  - Distance from camera

Example metadata structure:
```json
[
  {
    "frameIndex": 0,
    "utcTimestamp": "2024-01-01T12:00:00.000Z",
    "timestampSeconds": 1704110400.0,
    "cameraIntrinsics": {
      "m11": 1000.0, "m12": 0.0, "m13": 360.0,
      "m21": 0.0, "m22": 1000.0, "m23": 640.0,
      "m31": 0.0, "m32": 0.0, "m33": 1.0
    },
    "detections": [
      {
        "id": 0,
        "center": {"x": 640, "y": 360},
        "corners": [...],
        "position": {"x": 0.1, "y": 0.2, "z": 0.5},
        "rotation": {...},
        "distance": 0.55
      }
    ]
  }
]
```
