import SwiftUI

struct PetView: View {
    var body: some View {
        Image(systemName: "cat.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(red: 0.38, green: 0.46, blue: 0.61))
            .frame(width: 64, height: 64)
            .accessibilityLabel("Pet")
    }
}
