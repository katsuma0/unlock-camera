import SwiftUI
import Photos
import CameraCore

/// Where the photo info tool reads a picture from.
enum PhotoInfoSource {
    /// A file picked from Photos or Files, copied into the app's temporary folder.
    case file(URL)
    /// A photo in the library, read from its original resource.
    case asset(PHAsset)
}

/// Everything a picture's file says about it. Stub: the photo info builder fills it in.
struct PhotoInfoView: View {
    let source: PhotoInfoSource

    var body: some View {
        List {}
    }
}
