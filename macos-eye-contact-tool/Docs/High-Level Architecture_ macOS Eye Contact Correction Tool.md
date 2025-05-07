# High-Level Architecture: macOS Eye Contact Correction Tool

## 1. Overview

This document outlines the high-level architecture for a real-time eye contact correction application for macOS, optimized for Apple Silicon (M-series chips) and leveraging the Apple Neural Engine (ANE). The application will function as a virtual camera, selectable in video conferencing software, and provide a native macOS user interface for control.

## 2. Core Components

### 2.1. Camera Input (AVFoundation)
-   **Purpose:** Capture raw video frames from the selected physical camera (e.g., built-in FaceTime HD Camera).
-   **Implementation:** Use `AVCaptureSession` to manage the capture pipeline.
-   **Configuration:** Configure the session for an appropriate resolution and frame rate suitable for real-time processing and the input requirements of the ML model (e.g., 640x480 or 720p at 30fps). Specify the pixel format (e.g., `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`).
-   **Delegate:** Use `AVCaptureVideoDataOutputSampleBufferDelegate` to receive `CMSampleBuffer` objects containing video frames.

### 2.2. Video Processing Pipeline (Vision, Core ML)
-   **Purpose:** Detect faces/eyes, apply the gaze correction model, and generate corrected video frames.
-   **Face/Eye Detection (Vision):** Use `VNDetectFaceLandmarksRequest` within the Vision framework to accurately locate the user's eyes in each frame. This is crucial for applying the correction accurately.
-   **Gaze Correction Model (Core ML):**
    -   **Model:** Utilize a converted Core ML model (e.g., based on the 'gaze_correction' TensorFlow CNN) optimized for ANE execution.
    -   **Input:** Cropped eye regions or full face image, depending on the model's requirements, along with potentially the landmark data.
    -   **Execution:** Create a `VNCoreMLRequest` using the loaded `MLModel`. Process the request using a `VNImageRequestHandler` for each frame.
    -   **Output:** The model should output parameters needed for correction, such as a warping field or displacement map.
-   **Frame Correction (Core Image / Metal):** Apply the transformation predicted by the Core ML model to the original video frame. Core Image filters or custom Metal shaders can be used for efficient image warping based on the model's output.
-   **Efficiency:** Ensure the pipeline runs asynchronously off the main thread. Manage buffer processing carefully to avoid frame drops, potentially skipping model inference on some frames if processing falls behind.

### 2.3. Virtual Camera Output (CMIOExtension)
-   **Purpose:** Expose the processed video stream as a new system-wide camera source.
-   **Implementation:** Develop a Camera Management Input/Output (CMIO) extension. This extension registers a virtual device that applications like Zoom, Teams, FaceTime, etc., can recognize and select as a camera input.
-   **Data Flow:** The processed frames (as `CVPixelBuffer` or similar) are streamed to the virtual device provided by the CMIO extension.
-   **Note:** CMIO extensions run in a separate process and require specific entitlements and packaging.

### 2.4. User Interface (AppKit/SwiftUI, System Extensions)
-   **Purpose:** Provide user control over the eye contact feature (enable/disable, adjust intensity).
-   **Implementation:** Create a lightweight macOS application (potentially a menu bar app or integrated with Control Center via ControlCenterServices).
-   **Controls:** Implement a simple toggle switch for enabling/disabling the effect and a slider for adjusting the correction intensity (if the model/warping allows for variable intensity).
-   **Style:** Design the UI to mimic native macOS camera controls (like Portrait, Studio Light) for seamless integration, as requested.
-   **Communication:** The UI application needs to communicate with the video processing pipeline/CMIO extension (e.g., via XPC or shared user defaults) to control the effect's state and parameters.

## 3. Technology Stack
-   **Language:** Swift (preferred for modern macOS development), potentially Objective-C for specific framework interactions.
-   **Frameworks:**
    -   AVFoundation: Camera capture.
    -   Vision: Face/landmark detection, Core ML model integration.
    -   Core ML: Running the optimized gaze correction model (targeting ANE).
    -   Core Image / Metal: Efficient image warping/processing.
    -   CMIOExtension framework: Creating the virtual camera device.
    -   AppKit / SwiftUI: Building the user interface.
    -   XPC: Inter-process communication between the UI app and the CMIO extension/processing logic.

## 4. Optimization for Apple Silicon
-   **ANE Target:** Ensure the Core ML model is compiled and configured to prioritize ANE execution (`computeUnits = .all` or `.cpuAndNeuralEngine`).
-   **Metal:** Leverage Metal Performance Shaders or custom Metal kernels for GPU-accelerated image processing tasks (like warping) if needed.
-   **Grand Central Dispatch (GCD):** Use GCD extensively to manage asynchronous tasks and keep the main thread responsive.
-   **Memory Management:** Efficiently manage `CMSampleBuffer` and `CVPixelBuffer` objects to minimize memory footprint and copying.

## 5. Repository Structure (Proposed)
```
/macos-eye-contact-tool
|-- App/ (Main UI Application - Menu bar/Control Center)
|   |-- Source/
|   |-- Resources/
|   |-- EyeContactApp.xcodeproj
|-- EyeContactExtension/ (CMIO Virtual Camera Extension)
|   |-- Source/
|   |-- EyeContactExtension.xcodeproj
|-- Shared/ (Code shared between App and Extension, e.g., constants, IPC helpers)
|   |-- Source/
|-- Models/ (Core ML model files, conversion scripts)
|   |-- OriginalModel/ (e.g., TensorFlow files)
|   |-- ConvertedModel/ (e.g., .mlmodel, .mlpackage)
|   |-- conversion_script.py
|-- Docs/ (Documentation, Architecture diagrams)
|-- README.md
|-- LICENSE
```




## 6. Real-Time Video Processing Pipeline

This section details the step-by-step flow for processing each video frame in real-time:

1.  **Frame Capture (AVFoundation):**
    *   The `AVCaptureSession`, running on a dedicated background thread, captures a frame from the physical camera.
    *   The `AVCaptureVideoDataOutputSampleBufferDelegate` method `captureOutput(_:didOutput:from:)` is called on its specified dispatch queue, providing the frame as a `CMSampleBuffer`.

2.  **Initial Check & Frame Preparation:**
    *   Check if the eye contact correction feature is enabled (via shared state from the UI app).
    *   If disabled, directly enqueue the original `CMSampleBuffer` (or its `CVPixelBuffer`) to the CMIO virtual camera stream (Step 8) and skip subsequent processing steps for this frame.
    *   If enabled, extract the `CVPixelBuffer` from the `CMSampleBuffer`.
    *   Determine the correct `CGImagePropertyOrientation` based on device orientation and camera position.

3.  **Concurrency Control:**
    *   Before starting intensive processing, check if a previous frame is still being processed (e.g., using an `Atomic` flag or `DispatchSemaphore` with a value of 1).
    *   If processing is ongoing, drop the current frame to prevent latency buildup and resource exhaustion. If processing is free, mark it as busy and proceed.

4.  **Dispatch to Processing Queue:**
    *   Dispatch the actual processing tasks (Vision, Core ML, Warping) asynchronously to a dedicated serial background queue (`DispatchQueue`) to avoid blocking the AVFoundation capture queue.

5.  **Face & Landmark Detection (Vision):**
    *   Create a `VNImageRequestHandler` with the `CVPixelBuffer` and the determined orientation.
    *   Create and perform a `VNDetectFaceLandmarksRequest`.
    *   If no face or landmarks are detected, pass the original frame to the output (Step 8) and mark processing as complete for this frame.

6.  **Gaze Correction Inference (Core ML via Vision):**
    *   Using the detected landmarks, prepare the input for the gaze correction `MLModel` (e.g., crop eye regions, provide landmark coordinates).
    *   Create a `VNCoreMLRequest` using the loaded and ANE-optimized gaze correction model.
    *   Perform the request using the `VNImageRequestHandler`.
    *   The completion handler receives the model's output (e.g., warp parameters, displacement map).

7.  **Frame Warping (Core Image / Metal):**
    *   Based on the output from the Core ML model, apply the gaze correction warp to the original `CVPixelBuffer`.
    *   **Option A (Core Image):** Create a `CIImage` from the buffer. Use `CIWarpKernel` or other relevant Core Image filters, feeding in the warp parameters from the model, to generate the corrected `CIImage`. Render the result back to a `CVPixelBuffer`.
    *   **Option B (Metal):** For maximum performance, write a custom Metal compute shader (`MTLComputeCommandEncoder`) that takes the original buffer and the warp parameters as input textures/buffers and writes the warped output to a destination `MTLTexture` (backed by a `CVPixelBuffer`).
    *   This step produces the final, gaze-corrected `CVPixelBuffer`.

8.  **Output to Virtual Camera (CMIO Extension):**
    *   Obtain the final `CVPixelBuffer` (either original or warped).
    *   Send this buffer to the CMIO Extension's stream source. The extension typically uses a mechanism like `CMSimpleQueueEnqueue` or a shared memory buffer pool to pass the frame data efficiently.
    *   The CMIO extension signals that a new frame is available, making it accessible to applications using the virtual camera.

9.  **Cleanup & Concurrency Release:**
    *   Release any retained buffers or resources for the processed frame.
    *   Mark processing as complete (e.g., release the semaphore or reset the atomic flag) to allow the next frame to be processed.

This pipeline prioritizes real-time performance by using dedicated queues, asynchronous processing, frame dropping under load, and leveraging hardware acceleration (ANE via Core ML, GPU via Metal/Core Image).



## 7. User Interface (UI) and User Experience (UX) Requirements

Based on user feedback and the goal of seamless integration, the UI/UX will adhere to the following principles:

1.  **Integration Point:**
    *   **Primary:** A macOS Menu Bar application (`NSStatusItem`). This provides persistent but unobtrusive access to controls.
    *   **Alternative/Future:** Integration with Control Center using `ControlCenterServices` for an even more native feel, potentially replacing or supplementing the Menu Bar item.

2.  **Controls:**
    *   **Master Toggle:** A standard macOS switch (`NSSwitch` or SwiftUI `Toggle`) labeled "Eye Contact Correction" to enable or disable the effect globally for the virtual camera feed.
    *   **Intensity Slider:** A standard macOS slider (`NSSlider` or SwiftUI `Slider`) labeled "Correction Intensity".
        *   Enabled only when the Master Toggle is ON.
        *   Range: 0% to 100% (or similar intuitive scale).
        *   Allows the user to fine-tune the strength of the gaze correction effect.
        *   Requires the underlying warping mechanism (Core Image/Metal) to support variable intensity based on model output or a scaling factor.
    *   **(Optional) Physical Camera Selection:** If multiple cameras are common, a dropdown (`NSPopUpButton` or SwiftUI `Picker`) might be needed in a settings panel to select the source physical camera for processing. Initially, defaulting to the system's default video input device is sufficient.

3.  **Visual Style & Behavior:**
    *   **Native Look & Feel:** Strictly adhere to Apple's Human Interface Guidelines (HIG) for macOS. Use standard system controls, fonts, colors, and layout principles.
    *   **Menu Bar Icon:** A clear, simple icon for the `NSStatusItem` that visually indicates the status (e.g., monochrome icon, changes slightly when active vs. inactive).
    *   **Menu:** Clicking the Menu Bar icon reveals a simple menu containing the toggle switch and the intensity slider.
    *   **Responsiveness:** Controls should immediately reflect the state of the correction effect and update the processing pipeline via the chosen IPC mechanism (XPC).

4.  **Feedback:**
    *   The Menu Bar icon provides passive status feedback.
    *   The state of the controls (toggle on/off, slider position) provides active feedback.

5.  **Simplicity & Focus:**
    *   The UI should be minimal and focused solely on controlling the eye contact feature.
    *   Avoid complex settings or unnecessary options to maintain ease of use.

6.  **Onboarding/Setup:**
    *   Minimal setup required. The main action for the user is selecting the "Eye Contact Camera" (the virtual camera created by the CMIO extension) within their desired video conferencing application.
    *   Provide simple instructions within the app or README on how to select the virtual camera.



## 8. Development and Deployment Steps

This section outlines the key phases and steps involved in developing and deploying the macOS eye contact correction tool:

1.  **Environment Setup:**
    *   Install Xcode (latest version recommended) on an Apple Silicon Mac.
    *   Install Python and necessary libraries (e.g., `tensorflow`, `coremltools`) for model conversion.
    *   Set up a new Xcode project with two main targets: a macOS Application (for the UI) and a System Extension (CMIO Camera Extension).

2.  **Model Conversion & Optimization:**
    *   Obtain the pre-trained TensorFlow 1.x model files from the `chihfanhsu/gaze_correction` repository (or retrain if necessary).
    *   Use `coremltools` (Python library) to convert the TensorFlow model (`.pb` or SavedModel) into the Core ML format (`.mlmodel` or `.mlpackage`).
        *   Specify input/output types and shapes correctly.
        *   Use the Unified Converter API.
        *   Set `compute_units=coremltools.ComputeUnit.ALL` or `.CPU_AND_NE` to enable ANE optimization.
    *   Test the converted model with sample data to ensure conversion accuracy.
    *   Integrate the `.mlmodel` / `.mlpackage` file into the Xcode project (specifically targeting the CMIO extension or a shared framework).

3.  **CMIO Virtual Camera Extension:**
    *   Implement the `CMIOExtensionProviderSource` to create and manage the virtual camera device.
    *   Define the device properties (name like "Eye Contact Camera", manufacturer, model UID).
    *   Implement the `CMIOExtensionStreamSource` to handle video stream formats (matching the output of the processing pipeline) and frame timing.
    *   Set up the mechanism for receiving processed frames (e.g., a shared buffer queue, XPC connection with memory sharing) from the pipeline.
    *   Handle client connections (applications connecting to the virtual camera).
    *   Configure necessary entitlements for System Extensions.

4.  **Real-Time Processing Pipeline Implementation:**
    *   Implement the pipeline logic (likely within the CMIO extension process or a helper XPC service for better separation/stability).
    *   Set up `AVCaptureSession` to capture from the physical camera.
    *   Integrate `VNDetectFaceLandmarksRequest` for eye tracking.
    *   Load the converted Core ML model and create `VNCoreMLRequest`.
    *   Implement the frame warping logic using Core Image (`CIWarpKernel`) or Metal Performance Shaders / custom Metal kernels.
    *   Manage asynchronous processing using GCD, handle frame dropping, and ensure efficient buffer management.
    *   Implement the logic to toggle the effect and adjust intensity based on external commands (from the UI app).

5.  **UI Application (Menu Bar / Control Center):**
    *   Develop the macOS application using AppKit or SwiftUI.
    *   Create the `NSStatusItem` (Menu Bar icon) and its associated menu.
    *   Implement the toggle switch and intensity slider controls.
    *   Set up XPC communication to send commands (enable/disable, set intensity) to the CMIO extension / processing pipeline.
    *   Persist user settings (e.g., enabled state, intensity level) using `UserDefaults`.

6.  **Integration and Testing:**
    *   Thoroughly test the XPC communication between the UI app and the extension.
    *   Test the virtual camera functionality in various target applications (Zoom, Teams, FaceTime, OBS, QuickTime).
    *   Profile performance using Xcode Instruments (CPU, GPU, Memory, Energy, Core ML instrument) on the target Apple Silicon hardware (M3 Mac).
    *   Iteratively optimize the pipeline for low latency and efficient resource usage.
    *   Test different lighting conditions and head poses.

7.  **Packaging & Deployment:**
    *   Configure code signing for both the application and the system extension (requires an Apple Developer account).
    *   Enable Hardened Runtime and configure necessary entitlements.
    *   Build the application archive.
    *   **Deployment Options:**
        *   **Manual:** Distribute the `.app` bundle. Users will need to manually copy it to `/Applications` and approve the system extension upon first run.
        *   **Installer Package (.pkg):** Create an installer package for easier distribution and installation.
        *   **(Optional) Notarization:** Submit the application to Apple for notarization to improve user trust and bypass certain Gatekeeper warnings.

8.  **Repository & Documentation:**
    *   Set up the Git repository following the proposed structure.
    *   Write a comprehensive `README.md` explaining the project, features, setup, usage, and build instructions.
    *   Include the `architecture_design.md` document in the `Docs/` folder.
    *   Add code comments explaining complex sections.
    *   Include the appropriate open-source license (e.g., matching the license of the original model if required, or a permissive license like MIT/BSD).




## 9. Feasibility and Potential Limitations

### 9.1. Feasibility Assessment

Based on the research and design outlined, the development of this macOS eye contact correction tool is considered **technically feasible**, leveraging established Apple frameworks and technologies:

*   **Core Technologies:** The proposed architecture relies on standard macOS frameworks (AVFoundation, Vision, Core ML, Core Image/Metal, CMIO Extensions, AppKit/SwiftUI, XPC) designed for such tasks.
*   **Apple Silicon Optimization:** Core ML's ability to target the ANE, combined with Metal for GPU acceleration, provides a strong foundation for achieving real-time performance on M-series Macs (including the target M3).
*   **Model Conversion:** `coremltools` officially supports the conversion of TensorFlow 1.x models, making the adaptation of the identified open-source model (`chihfanhsu/gaze_correction`) viable, although practical testing is needed to confirm compatibility of all layers.
*   **Virtual Camera:** CMIO Extensions are the standard mechanism for creating system-wide virtual cameras on modern macOS.
*   **Native UI:** Building a native macOS UI (Menu Bar app) that communicates with the backend via XPC is a common and achievable pattern.

### 9.2. Potential Limitations and Challenges

Despite the overall feasibility, several potential limitations and challenges should be considered during development:

*   **Correction Quality:** The visual quality and naturalness of the eye contact correction are highly dependent on the effectiveness of the underlying open-source ML model. It may exhibit artifacts, unnatural warping, or fail under certain conditions (e.g., extreme head poses, poor lighting, glasses, partial face visibility). Achieving quality comparable to commercial solutions like Nvidia Broadcast or Apple's built-in FaceTime feature might require significant model refinement, retraining, or exploring alternative models.
*   **Performance & Latency:** While optimized for Apple Silicon, the real-time processing pipeline (detection, inference, warping) will introduce some latency. Achieving consistently low latency (<30-50ms) to feel natural in live calls requires careful optimization and may depend heavily on the specific M-series chip and the complexity of the chosen model/warping algorithm. Performance profiling (using Xcode Instruments) is crucial.
*   **Resource Usage:** Continuous video processing and ML inference will consume significant CPU, GPU, ANE, and memory resources. This could impact battery life on MacBooks and potentially affect the performance of other applications, especially during resource-intensive video calls. Efficient implementation and potential quality/performance trade-offs (e.g., adaptive frame skipping) are necessary.
*   **Model Conversion Issues:** While `coremltools` supports TF1.x, specific unsupported layers or operations in the original model could complicate the conversion process, potentially requiring custom Core ML layers (which might not run on ANE) or model architecture modifications.
*   **CMIO Extension Complexity & Stability:** Developing and debugging CMIO extensions is inherently more complex than standard application development. They run in a separate process, require specific entitlements, and rely on IPC (XPC). Stability issues or conflicts with other camera software could arise. User approval is required for installation.
*   **Compatibility:** Ensuring compatibility across different macOS versions and various video conferencing applications requires thorough testing.
*   **Development Effort:** This project involves multiple advanced macOS frameworks and requires significant development time and expertise in Swift/Objective-C, computer vision, ML deployment, and system extensions.

