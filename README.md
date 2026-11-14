# Open Shutter

Open Shutter is an iPhone camera app with the manual controls iOS lets an app touch. Shutter speed from the fastest the sensor allows out to 30 minutes, ISO, white balance in Kelvin and tint, manual focus, exposure compensation, every back lens, and on an iPhone 18 Pro the aperture itself.

It opens as a plain camera. Four modes, everything on auto, no shutter speeds or ISO anywhere on the screen. The first launch asks whether you want that or the advanced interface, and a switch at the top of Settings changes the answer later. Advanced adds manual mode and everything in the list below. Turning it off puts what it changed back on automatic, and turning it on again brings your settings back.

The sensor can't hold a single frame open much longer than a second. Anything longer here is built from frames: a 30 second exposure is thirty 1 second frames added together on the GPU, which is what light does on a sensor anyway, so the brightness matches a real 30 second shot. Night mode works the same way with alignment and averaging, and it takes any duration you give it between 1 and 30 seconds instead of Apple's presets.

What's in it:

- Shutter, ISO, aperture and EV on ruler dials, each one auto or locked. Lock one and the others follow it, so shutter priority, ISO priority and aperture priority all work. With an Xcode 27 build on iOS 27, iOS runs those natively; otherwise a meter loop in the app does. On iOS 26 and later, auto exposure can meter a small spot or the whole frame instead of the area around the point you tap.
- Aperture on variable aperture lenses (iPhone 18 Pro, iOS 27), using the stops Apple recommends for the lens.
- Long exposure scenes that set themselves up: Water, Light trails, Stars, Northern lights, Star trails, Fireworks and Light painting. Stars, for one, is 15 seconds with focus at infinity, white balance at 4000 K and ISO held under 3200, and on an iPhone 18 Pro the iris wide open. The tripod scenes wait a moment after the tap, so the press doesn't end up in the picture. In the advanced interface a scene is a starting point and every value can be changed.
- Long exposure with three blends. Real adds light like a long shutter. Blur averages frames, which looks like an ND filter at noon. Trails keeps the brightest pixels for car lights and stars. Blur and Trails can also fix the shutter of each frame. Bulb runs until you let go.
- Night mode from 1 to 30 seconds, handheld or tripod, with frame alignment and blur rejection.
- White balance presets, Kelvin from 2000 to 10000, tint, and a gray card button.
- Manual focus with focus peaking, tap to focus, AE/AF lock, autofocus range, and subject tracking on iOS 27.
- Lens buttons for each back camera plus the 2× crops of the 48 MP sensors (0.5×, 1×, 2×, 4× or 5×, and 8× on a 48 MP telephoto), and a flip button for the front camera. A tap zooms to the lens instead of cutting to it. Touch and hold the buttons and slide, and they turn into a zoom wheel that moves in tenths (1.4×, 2.7×) up to 10× and in whole steps after that. It stops where you let go. Pinch zoom switches lenses too.
- Aspect ratios 4:3, 1:1, 16:9, 3:2, 5:4, 2:1, 2.39:1 and 65:24, or any ratio you type in. 16:9 is the default. It fills the width of the screen and the controls sit over the picture, the way Apple's Camera does it. The bands above and below start black and fade to see-through, so at 1:1 you can see what's just outside the frame. Taking a photo blinks the picture black; the buttons stay put.
- A tripod sign for Night, Long exposure and any manual shutter built from frames, in a big pill above the shutter: Use a tripod, Hold still or Steady before the shot, Keep still while the frames come in, and The phone moved when it gets bumped. Handheld, two crosses show how far the phone has turned since the start, and the job is to keep them on top of each other. Night on a tripod waits a second after the press, and any wait holds on up to 3 seconds more while the phone still moves.
- A battery saver for long shots, off until you turn it on. On a shot of 10 seconds or more, the screen goes black 3 seconds in and lights up again for the last 5 seconds, whenever the phone moves, and for 10 seconds after a touch.
- Self timer up to 10 minutes, an intervalometer (up to 9999 shots, up to an hour apart), and exposure, focus or white balance brackets.
- HEIF, JPEG, RAW, ProRAW and RAW plus either, 12 or 48 MP, compression quality, and how much Apple processing you want.
- Histogram (luma or RGB), zebras, false color, level, grids, clipping warnings and a live readout with a light meter.
- Video with manual exposure, frame rate, resolution, HEVC, H.264 or ProRes, HDR, Apple Log or Apple Log 2, every stabilization mode the phone offers, wind noise reduction, and the torch.
- The Camera Control button carries zoom, lens, exposure, shutter, ISO and white balance by default. Aperture, focus and mode can be swapped in from Settings. Each volume button takes a job: shutter, zoom in, zoom out, brighter, darker or next lens. A Camera Control click does what volume down does, and any of them stops a running shot. Haptics come in Off, Light, Normal and Strong, with their own switches for dial ticks and zoom ticks.
- A top bar you arrange yourself: three buttons on the left and two on the right, from 22 choices (flash, Live Photo, timer, aspect ratio, grid, level, location, quiet shutter, battery saver, night length, RAW, exposure lock, format, resolution, processing, histogram, zebras, peaking, false color, white balance, stabilization and sound). A button that doesn't apply in a mode steps aside. The pull-down quick settings are still there for the rest.
- Photo details like Apple's: lens, focal length, aperture, shutter, ISO, exposure mode and compensation, metering, white balance, flash, and where it was taken, but only if you turn on location tags, which start off. It also writes down what Apple's camera has no field for: the mode and scene, which values you set by hand, the zoom, the timer, the bracket a photo belongs to, and for stacked shots the frames, the blend, the time per frame and whether the phone was steady. Your name and copyright go in too, if you type them in Settings.
- A gallery of what you took with the app (it leaves the rest of your library alone), and a first round of edits: exposure, highlights, shadows, contrast, brightness, saturation, vibrance, warmth, tint, sharpness, vignette, nine looks, crop, straighten, rotate and flip. Edits go into Photos without losing the original, so Revert to original works here or in the Photos app, and Save as copy puts the edit next to the original instead. A Live Photo takes the color changes only, and an HDR photo saves its edit in standard range for now.
- A photo info page in Settings. Open any image from your library or Files and it lists every piece of metadata the file carries. It can save a copy with the location taken out, or with everything taken out.
- Settings in light, dark or whatever the phone uses, with seven accent colors. For accessibility there are larger labels, solid buttons that don't depend on the picture behind them, reduce motion, a left-handed layout, and spoken status, which reads out the countdown and says Keep the phone still and Done. Bold Text, Increase Contrast and VoiceOver work too.
- Preserve settings like Apple's: the mode, the lens and zoom, and the exposure can each stay where you left them or start fresh. Also Prioritize faster shooting, and Allow audio playback, which lets music keep playing while you film.
- Touch and hold on most buttons lists their choices: flash, video light brightness, timer, video format, the manual chips with their common values. Every dial has a Done button that brings the modes back, and a swipe down does the same.
- A settings page for the capture, exposure, focus, video and control options, and a page listing what your camera reports: every format, range and feature.

## Running it

Open `OpenShutter.xcodeproj` and press Run. The Simulator has no camera, so it gets a fake night street with moving car lights instead. That's enough to try every dial, the long exposure trails, night mode and the settings. Xcode 26 and Xcode 27 both build it for the Simulator.

On a phone you need iOS 18 or later. Choose your team under Signing & Capabilities, and turn on Developer Mode on the phone (Settings, Privacy & Security, Developer Mode). With a free Apple ID you also have to trust yourself under Settings, General, VPN & Device Management. The first launch asks simple or advanced, then for the camera. After that it asks for adding to Photos at the first save, for your library when you open the gallery and tap Continue, for the microphone the first time you switch to video with sound on, and for location only if you turn on location tags.

The iPhone 18 Pro ships with iOS 27, which means Xcode 27; Xcode 26 can't install on it. Everything new in iOS 27 only compiles with Xcode 27 anyway: the aperture, native priority modes, subject tracking and low light video noise reduction. Built with Xcode 26, for the Simulator or a phone on iOS 26, the app treats every lens as fixed aperture and runs priority modes with its own meter loop.

To try the fake camera on a real phone, turn on the `-simulatedCamera` argument in the scheme (Product, Scheme, Edit Scheme, Run, Arguments). Its shots of the fake street go into your real photo library.

The camera math lives in `Packages/CameraCore`: plain Swift and Foundation, with no camera or UI frameworks, so it builds and tests anywhere Swift runs. Cmd+U in Xcode runs its tests, or `swift test` in that folder.

## What it can't do

Apple keeps some things to its own Camera app. Its Night mode, Photographic Styles, Portrait mode rendering and Action mode aren't available to other apps, so they aren't here. The night mode in this app is my own frame stack. It's good on a tripod and decent handheld, and it won't beat Apple's on a shaky hand.

Manual exposure only works on the physical lenses, not on Apple's combined multi-lens camera, so lens changes take a beat and there's no automatic macro switch. For close-ups, pick 0.5× and focus by hand.

There's no 24 MP option. iOS only delivers 24 MP through deferred processing, and the app keeps that off so it can crop and save each photo itself. Bayer RAW needs a lens at its own zoom, like 0.5×, 1× or 4×. At 2×, 8× or with any pinch zoom you get the HEIF or JPEG alone, and the RAW chip dims to show it. ProRAW works at any zoom.

At 16:9 the bands above and below the picture stay black. Apple's Camera fills them from the ultra wide while you shoot on the main lens. This app runs one camera at a time, so there's nothing to put there. If you had an earlier build installed, your saved 4:3 stays until you tap the aspect ratio or reset the settings.

The extra photo details go into each file's XMP, under the namespace `http://ns.katsuma.ca/openshutter/1.0/`, and into videos as QuickTime keys starting with `ca.katsuma.openshutter.`. The Photos app shows the standard fields and ignores the rest; the photo info page shows all of it. Files are named `OpenShutter_` plus the date and time, so they're easy to pick out on a computer.

The battery saver covers the screen in black and turns the brightness down. It can't turn the screen off, because iOS stops the camera when it does.

The sky scenes park the focus at the far end of the lens. Apple doesn't promise that is infinity on every lens, so if stars come out soft, set the focus by hand in the advanced interface.

Silent shutter only appears where iOS allows it. Exposure brackets are one burst, capped at what the phone reports, usually three to five frames. Focus brackets (up to 30 frames) and white balance brackets (up to 9) are separate shots. Stacked exposures are built from the video stream, so they're 12 MP even on a 48 MP sensor, and they save as HEIF or JPEG, not RAW.

If you leave the app in the middle of a long exposure, it keeps the frames it has and finishes the photo when you come back. Apps in the background get no GPU, so that last step has to wait.

The name is Open Shutter because that is what a long exposure is.
