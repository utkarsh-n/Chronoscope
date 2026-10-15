# Continuous map navigation

Hold a movement arrow to glide continuously. Slide the same finger farther from its initial position to increase speed, then move it back for finer control. Lifting the finger brakes quickly. Rise, descend, and zoom use the same interaction. The direction remains attached to the arrow where the touch began, so a drag cannot accidentally turn into a camera-look gesture or another arrow command.

On hardware that reports real touch force, that force can also increase input strength. Other devices use deliberate drag distance and a gentle hold ramp. Touch area is not interpreted as pressure. This preserves a predictable interaction on the iPhone 15 Pro Max without presenting Haptic Touch as a force sensor. Native assistive activation and keyboard navigation retain modest steps.

Controls have 44-point targets, active glass tint, a strength outline, and one subtle touchdown haptic. Reduce Transparency uses opaque faces. Reduce Motion removes the icon displacement and release inertia. Leaving the map, losing foreground activity, cancelling a touch, or resetting/recentering the camera cancels the input. An excessive drag outside the safety area cancels tracking until a fresh touch.

The shared Core motion model integrates velocity and displacement analytically, normalizes diagonal inputs, cancels opposite inputs, and caps a late frame at 50 milliseconds to prevent a jump after suspension. The animation task runs only while a touch or braking motion exists; touch display links run only while a finger is held. Camera updates query no catalog data. Debug-only navigation verification is opt-in with `CHRONOSCOPE_VERIFY_NAVIGATION=1` and is absent from Release UI.
