import SwiftUI

/// Main window. Empty for now: the galleries arrive with F1 (SD card) and F2 (existing folder).
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "Aucune galerie",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Importez une carte SD ou un dossier de photos pour commencer.")
        )
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
