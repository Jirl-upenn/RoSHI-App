# <img src="https://roshi-mocap.github.io/static/img/roshi.png" alt="RoSHI Logo" height="32"> RoSHI-App

[Project Page](https://roshi-mocap.github.io/) | [Documentation](https://roshi-mocap.github.io/documentation/) | [Main Repository](https://github.com/Jirl-upenn/RoSHI-MoCap)

An iOS app for calibrating the [RoSHI](https://roshi-mocap.github.io/) whole-body motion capture system. It captures RGB video with real-time AprilTag detection and synchronizes with 9 body-mounted IMU sensors over LAN to estimate bone-to-sensor orientation offsets.

## Core Capabilities

- Real-time AprilTag detection (Tag36h11) with 3D pose overlay
- Video recording with per-frame UTC timestamps and camera intrinsics
- LAN receiver connection with configurable IP and port

## Requirements

- iPhone or iPad running **iOS 17.6+**
- **Xcode 15+** with Swift 5.0
- A RoSHI receiver running on the same LAN from the [main RoSHI-MoCap repository](https://github.com/Jirl-upenn/RoSHI-MoCap)

## Quick Start

```bash
git clone git@github.com:Jirl-upenn/RoSHI-App.git
cd RoSHI-App
```

1. Open `ROSHI.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, select your Apple Development Team.
3. Select your target device (iPhone or iPad).
4. Build and run (Cmd+R).

No external Swift packages or CocoaPods are needed; the AprilTag library is vendored as C source.

Start the receiver from the main RoSHI-MoCap repository on a computer connected to the same network:

```bash
git clone git@github.com:Jirl-upenn/RoSHI-MoCap.git
cd RoSHI-MoCap
python 01_receiver.py --output-dir received_recordings
```

Start the receiver on the same network as the iOS device, then enter the IP address and port shown in the receiver terminal in the app settings.

## Documentation

Detailed setup and usage notes have been moved to the documentation site:

- [Calibration App Setup](https://roshi-mocap.github.io/documentation/calibration/app_setup.html)
- [Calibration App Reference](https://roshi-mocap.github.io/documentation/calibration/app_reference.html)
- [Calibration Procedure](https://roshi-mocap.github.io/documentation/calibration/procedure.html)
- [Hardware Components and Tag Placement](https://roshi-mocap.github.io/documentation/hardware/components.html)

## License

MIT License. See [LICENSE](LICENSE) for details.

This project is part of the RoSHI system developed at the [JIRL Lab](https://github.com/Jirl-upenn), University of Pennsylvania.
