//
//  ContentView.swift
//  mac-os-eye-correction
//
//  Created by Oleksandr Tsepukh on 04/05/2025.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.badge.ellipsis")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.blue)

            Text("Eye Correction Virtual Camera")
                .font(.title)

            Text("This application provides a virtual camera extension that attempts to correct eye gaze.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("How to use:")
                    .font(.headline)
                Text("1. Build and run this application once.")
                Text("2. Open an application that uses a camera (e.g., FaceTime, Zoom, Photo Booth)." )
                Text("3. Select 'Eye Correction Virtual Camera' from the camera list.")
                Text("4. The virtual camera will use your default physical camera and apply eye correction.")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(8)

        }
        .padding()
        .frame(minWidth: 400, minHeight: 350)
    }
}

#Preview {
    ContentView()
}
