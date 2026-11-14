import SwiftUI

/// The Tools section of Settings, the same at both interface levels: the photo info tool shows a file's own data
/// under its standard names, which are the same words for everyone.
struct PhotoToolsSection: View {
    var body: some View {
        Section {
            NavigationLink("Photo info") {
                PhotoInfoToolView()
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Shows everything saved inside a photo, such as the camera, its settings, the date and the place, and saves a copy without it.")
        }
    }
}
