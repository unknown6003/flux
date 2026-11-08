# Mirror lifetime

The new Mirror uses AVFoundation's preview layer. It adds one camera input and no microphone, frame-copy output, image cache or recording. The parent creates a driver only for a visible Mirror with an existing camera grant. The service checks the grant again and never prompts. The widget will offer an explicit permission action through the app coordinator.

CameraDriver owns configuration, start and stop on one actor. Apple's documentation says startRunning blocks, so it must stay off the UI actor. The immutable preview-source bridge follows the separation described in Apple's AVCam sample. The view gets a preview connection rather than the session's controls.

- [AVCaptureSession and its blocking startup](https://developer.apple.com/documentation/avfoundation/avcapturesession)
- [AVCam's preview-source separation](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)

CameraFeed.stop cancels startup, rejects late state, asks the driver to stop and releases the layer connection after stop completes. A deinit task is a second idempotent stop. This is asynchronous shutdown, not an instant hardware-off claim. Real Mac tests must measure stop latency, the camera indicator, retained memory and quick reopen behavior.

The first implementation has no runtime interruption or device-disconnect observer yet. Its fixed states and error paths contain no device name or raw error. It is not complete feature acceptance and is not wired into the app.
