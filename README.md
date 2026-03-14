# RoSHI-App

An iOS app for calibrating the [RoSHI](https://github.com/Jirl-upenn/RoSHI) whole-body motion capture system. It captures RGB video with real-time AprilTag detection and synchronizes with 9 body-mounted IMU sensors over LAN to estimate bone-to-sensor orientation offsets.

## Features

- Real-time AprilTag detection (Tag36h11) with 3D pose overlay
- Video recording with per-frame UTC timestamps and camera intrinsics
- Automatic LAN receiver discovery via Bonjour/mDNS
- Per-tag detection tracker with configurable target counts
- Front/back camera support with adjustable resolution, FPS, and zoom
- Session-based recording with start/stop synchronization signals for IMU capture

## Requirements

### Hardware

- iPhone or iPad running **iOS 17.6+**
- 9 AprilTags (Tag36h11 family, IDs 0–8, 42 mm tag size) attached to the body
- A computer on the same LAN to run the receiver script

### Tag Placement


| Tag ID | Body Location  |
| ------ | -------------- |
| 0      | Pelvis         |
| 1      | Left Shoulder  |
| 2      | Right Shoulder |
| 3      | Left Elbow     |
| 4      | Right Elbow    |
| 5      | Left Hip       |
| 6      | Right Hip      |
| 7      | Left Knee      |
| 8      | Right Knee     |


### Software

- **Xcode 15+** with Swift 5.0
- **Python 3.7+** (for the receiver)

## Getting Started

### 1. Clone the repository

```bash
git clone git@github.com:Jirl-upenn/RoSHI-App.git
cd RoSHI-App
```

### 2. Build the iOS app

1. Open `ROSHI.xcodeproj` in Xcode.
2. Select your target device (iPhone or iPad).
3. Build and run (Cmd+R).

No external Swift packages or CocoaPods are needed — the AprilTag library is vendored as C source.

### 3. Set up the receiver

On your computer (must be on the same Wi-Fi network as the iOS device):

```bash
pip install -r requirements.txt
python3 receiver.py
```

The receiver will advertise itself via Bonjour. The app should discover it automatically, or you can enter the IP and port manually in the app's Receiver Settings.

**Options:**

```bash
python3 receiver.py --port 8080                    # custom port (default: 50000)
python3 receiver.py --output-dir ~/roshi_data      # custom output directory
```

## Usage

1. **Launch the app** and ensure the receiver status indicator (top-right) is green.
2. **Position the camera** so that the person wearing the tags is visible.
3. **Tap Record** — a 3-second countdown starts (front camera), then recording begins.
4. **Move to expose all 9 tags** — the tag detection tracker shows progress per tag.
5. **Tap Stop** when all tags reach the target detection count (or earlier with a warning).
6. The app automatically uploads the video and metadata to the receiver.

### App Settings


| Setting                   | Options           | Default |
| ------------------------- | ----------------- | ------- |
| Resolution                | 720p / 1080p      | 720p    |
| FPS                       | 10 / 15 / 20 / 30 | 30      |
| Target detections per tag | 50 / 100 / 200    | 100     |
| Zoom                      | 1×–5×             | 1×      |
| Camera                    | Front / Back      | Back    |


## Output Format

The receiver saves two files per recording session:

### Video (`video_YYYYMMDD_HHMMSS.mp4`)

H.264 encoded MP4 at the configured resolution and frame rate.

### Metadata (`metadata_YYYYMMDD_HHMMSS.json`)

A JSON array with one entry per frame:

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
        "corners": ["..."],
        "position": {"x": 0.1, "y": 0.2, "z": 0.5},
        "rotation": {"...": "..."},
        "distance": 0.55
      }
    ]
  }
]
```

## Architecture

```
ROSHI/
├── ROSHIApp.swift             # App entry point
├── ContentView.swift          # Main UI, AppModel state management
├── CameraManager.swift        # AVFoundation camera session
├── VideoRecorder.swift        # Video + metadata recording
├── AprilTagDetector.swift     # AprilTag detection (Swift ↔ C bridge)
├── FileTransferService.swift  # LAN file transfer to receiver
├── apriltag.c/h               # Vendored AprilTag C library
├── apriltag_pose.c/h          # Tag 3D pose estimation
└── common/                    # AprilTag support (image, matrix, etc.)
```

## Troubleshooting


| Issue               | Solution                                                                       |
| ------------------- | ------------------------------------------------------------------------------ |
| Receiver not found  | Ensure both devices are on the same Wi-Fi network. Check firewall settings.    |
| Connection timeout  | Verify the port is not blocked. Try entering IP/port manually in app settings. |
| Tags not detected   | Ensure tags are printed at 42 mm size, flat, and well-lit. Avoid motion blur.  |
| Low detection count | Move slowly, keep tags facing the camera, increase recording duration.         |


## Related

- [RoSHI](https://github.com/Jirl-upenn/RoSHI) — Main project: whole-body IMU motion capture pipeline

## License

This project is part of the RoSHI system developed at the [JIRL Lab](https://github.com/Jirl-upenn), University of Pennsylvania.

