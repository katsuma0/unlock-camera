# Open Shutter

Open Shutter is an iPhone camera app with the manual controls iOS lets an app touch. Shutter speed from the fastest the sensor allows out to 30 minutes, ISO, white balance in Kelvin and tint, manual focus, exposure compensation, every back lens, and on an iPhone 18 Pro the aperture itself.

The sensor can't hold a single frame open much longer than a second. Anything longer here is built from frames: a 30 second exposure is thirty 1 second frames added together on the GPU, which is what light does on a sensor anyway, so the brightness matches a real 30 second shot. Night mode works the same way with alignment and averaging, and it takes any duration you give it between 1 and 30 seconds instead of Apple's presets.

What's in it:

- Shutter, ISO, aperture and EV on ruler dials, each one auto or locked. Lock one and the others follow it, so shutter priority, ISO priority and aperture priority all work. With an Xcode 27 build on iOS 27, iOS runs those natively; otherwise a meter loop in the app does. On iOS 26 and later, auto exposure can meter a small spot or the whole frame instead of the area around the point you tap.
- Aperture on variable aperture lenses (iPhone 18 Pro, iOS 27), using the stops Apple recommends for the lens.
- Long exposure with three blends. Real adds light like a long shutter. Blur averages frames, which looks like an ND filter at noon. Trails keeps the brightest pixels for car lights and stars. Blur and Trails can also fix the shutter of each frame. Bulb runs until you let go.
- Night mode from 1 to 30 seconds, handheld or tripod, with frame alignment and blur rejection.
- White balance presets, Kelvin from 2000 to 10000, tint, and a gray card button.
- Manual focus with focus peaking, tap to focus, AE/AF lock, autofocus range, and subject tracking on iOS 27.
- Lens buttons for each back camera plus the 2× crops of the 48 MP sensors (0.5×, 1×, 2×, 4× or 5×, and 8× on a 48 MP telephoto), a flip button for the front camera, and pinch zoom that switches lenses.
- Aspect ratios 4:3, 1:1, 16:9, 3:2, 5:4, 2:1, 2.39:1 and 65:24, or any ratio you type in.
- Self timer up to 10 minutes, an intervalometer (up to 9999 shots, up to an hour apart), and exposure, focus or white balance brackets.
- HEIF, JPEG, RAW, ProRAW and RAW plus either, 12 or 48 MP, compression quality, and how much Apple processing you want.
- Histogram (luma or RGB), zebras, false color, level, grids, clipping warnings and a live readout with a light meter.
- Video with manual exposure, frame rate, resolution, HEVC, H.264 or ProRes, HDR, Apple Log or Apple Log 2, every stabilization mode the phone offers, wind noise reduction, and the torch.
- The Camera Control button carries zoom, lens, exposure, shutter, ISO and white balance by default. Aperture, focus and mode can be swapped in from Settings. The volume buttons take the picture too.
- A settings page for the capture, exposure, focus, video and control options, and a page listing what your camera reports: every format, range and feature.

## Running it

Open `OpenShutter.xcodeproj` and press Run. The Simulator has no camera, so it gets a fake night street with moving car lights instead. That's enough to try every dial, the long exposure trails, night mode and the settings. Xcode 26 and Xcode 27 both build it for the Simulator.

On a phone you need iOS 18 or later. Choose your team under Signing & Capabilities, and turn on Developer Mode on the phone (Settings, Privacy & Security, Developer Mode). With a free Apple ID you also have to trust yourself under Settings, General, VPN & Device Management. The app asks for the camera at launch, for adding to Photos at the first save, for the microphone the first time you switch to video with sound on, and for location only if you turn on location tags.

The iPhone 18 Pro ships with iOS 27, which means Xcode 27; Xcode 26 can't install on it. Everything new in iOS 27 only compiles with Xcode 27 anyway: the aperture, native priority modes, subject tracking and low light video noise reduction. Built with Xcode 26, for the Simulator or a phone on iOS 26, the app treats every lens as fixed aperture and runs priority modes with its own meter loop.

To try the fake camera on a real phone, turn on the `-simulatedCamera` argument in the scheme (Product, Scheme, Edit Scheme, Run, Arguments). Its shots of the fake street go into your real photo library.

The camera math lives in `Packages/CameraCore`: plain Swift and Foundation, with no camera or UI frameworks, so it builds and tests anywhere Swift runs. Cmd+U in Xcode runs its tests, or `swift test` in that folder.

## What it can't do

Apple keeps some things to its own Camera app. Its Night mode, Photographic Styles, Portrait mode rendering and Action mode aren't available to other apps, so they aren't here. The night mode in this app is my own frame stack. It's good on a tripod and decent handheld, and it won't beat Apple's on a shaky hand.

Manual exposure only works on the physical lenses, not on Apple's combined multi-lens camera, so lens changes take a beat and there's no automatic macro switch. For close-ups, pick 0.5× and focus by hand.

There's no 24 MP option. iOS only delivers 24 MP through deferred processing, and the app keeps that off so it can crop and save each photo itself. Bayer RAW needs a lens at its own zoom, like 0.5×, 1× or 4×. At 2×, 8× or with any pinch zoom you get the HEIF or JPEG alone, and the RAW chip dims to show it. ProRAW works at any zoom.

Silent shutter only appears where iOS allows it. Exposure brackets are one burst, capped at what the phone reports, usually three to five frames. Focus brackets (up to 30 frames) and white balance brackets (up to 9) are separate shots. Stacked exposures are built from the video stream, so they're 12 MP even on a 48 MP sensor, and they save as HEIF or JPEG, not RAW.

If you leave the app in the middle of a long exposure, it keeps the frames it has and finishes the photo when you come back. Apps in the background get no GPU, so that last step has to wait.

The name is Open Shutter because that is what a long exposure is.
