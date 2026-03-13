@preconcurrency import AVFoundation
import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers

/// Effects panel for configuring webcam overlays (city/time, name badge, logo).
/// Shows dual camera previews: mirrored ("What you see") and non-mirrored ("What they see").
struct WebcamEffectsView: View {
    @Binding var effects: WebcamEffects
    let webcamDeviceID: String?
    var onDismiss: () -> Void

    @StateObject private var preview = MediaPreviewModel()
    @State private var showLogoPicker = false

    // Font families available for overlays
    private static let fontFamilies = [
        "Helvetica Neue",
        "SF Pro",
        "Avenir Next",
        "Futura",
        "Gill Sans",
        "Menlo",
        "Georgia",
        "Palatino",
        "Arial",
        "Verdana",
        "Trebuchet MS",
        "Impact",
    ]

    // Common city/timezone pairs
    private static let cities: [(name: String, tz: String)] = [
        ("New York", "America/New_York"),
        ("Los Angeles", "America/Los_Angeles"),
        ("Chicago", "America/Chicago"),
        ("London", "Europe/London"),
        ("Paris", "Europe/Paris"),
        ("Berlin", "Europe/Berlin"),
        ("Tokyo", "Asia/Tokyo"),
        ("Shanghai", "Asia/Shanghai"),
        ("Dubai", "Asia/Dubai"),
        ("Sydney", "Australia/Sydney"),
        ("Mumbai", "Asia/Kolkata"),
        ("S\u{e3}o Paulo", "America/Sao_Paulo"),
        ("Toronto", "America/Toronto"),
        ("Singapore", "Asia/Singapore"),
        ("Hong Kong", "Asia/Hong_Kong"),
        ("Seoul", "Asia/Seoul"),
        ("Moscow", "Europe/Moscow"),
        ("Istanbul", "Europe/Istanbul"),
        ("Mexico City", "America/Mexico_City"),
        ("Johannesburg", "Africa/Johannesburg"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Dual preview
            HStack(spacing: 16) {
                previewPane(mirrored: true, caption: "What you see")
                previewPane(mirrored: false, caption: "What they see")
            }
            .padding(20)

            Divider()

            // Effect controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // City & Time
                    VStack(alignment: .leading, spacing: 6) {
                        Text("City & Time").font(.headline)
                        Text("Shows a city name and its current local time in the top-left corner.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("City name", text: $effects.cityName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Picker("Time zone", selection: $effects.timeZoneIdentifier) {
                                Text("Select\u{2026}").tag("")
                                Divider()
                                ForEach(Self.cities, id: \.tz) { city in
                                    Text("\(city.name) (\(Self.abbreviation(for: city.tz)))")
                                        .tag(city.tz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }

                    Divider()

                    // Display Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name Badge").font(.headline)
                        Text("Your name appears in the bottom-right corner, like a TV news anchor.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Display name", text: $effects.displayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }

                    Divider()

                    // Logo
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Logo").font(.headline)
                        Text("An image displayed in the top-right corner of the video.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            if let data = effects.logoPNGData, let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )

                                Button(role: .destructive) {
                                    effects.logoPNGData = nil
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .controlSize(.small)
                            }

                            Button {
                                showLogoPicker = true
                            } label: {
                                Label(
                                    effects.logoPNGData == nil ? "Choose Image\u{2026}" : "Replace\u{2026}",
                                    systemImage: "photo"
                                )
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Font settings
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Font").font(.headline)
                        HStack(spacing: 12) {
                            Picker("Family", selection: $effects.fontFamily) {
                                ForEach(Self.fontFamilies, id: \.self) { family in
                                    Text(family)
                                        .font(.custom(family, size: 13))
                                        .tag(family)
                                }
                            }
                            .frame(width: 180)

                            HStack(spacing: 4) {
                                Text("Size")
                                Slider(value: $effects.fontSizePercent, in: 2.5...8, step: 0.5)
                                    .frame(width: 100)
                                Text(String(format: "%.0f%%", effects.fontSizePercent))
                                    .monospacedDigit()
                                    .frame(width: 30, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            preview.startCamera(deviceID: webcamDeviceID)
        }
        .onDisappear {
            preview.stop()
        }
        .fileImporter(
            isPresented: $showLogoPicker,
            allowedContentTypes: [.png, .jpeg, .heic, .svg, .image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let nsImage = NSImage(contentsOf: url), let pngData = nsImage.pngRepresentation() {
                    effects.logoPNGData = pngData
                }
            }
        }
    }

    // MARK: - Preview Pane

    @ViewBuilder
    private func previewPane(mirrored: Bool, caption: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                CameraPreviewView(session: preview.captureSession)
                    .aspectRatio(4/3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                if !preview.cameraActive {
                    VStack(spacing: 4) {
                        Image(systemName: "video.slash")
                            .font(.title2)
                        Text("No camera")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                // Overlay effects (drawn on top of the camera preview)
                overlayEffects
            }
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - SwiftUI Overlay Effects

    @ViewBuilder
    private var overlayEffects: some View {
        GeometryReader { geo in
            let fontSize = max(8, geo.size.height * effects.fontSizePercent / 100)
            let margin = fontSize * 1.2

            // Top-left: city & time (CNN-style stacked box)
            if !effects.cityName.isEmpty {
                CityTimeBox(
                    cityName: effects.cityName,
                    timeZoneIdentifier: effects.timeZoneIdentifier,
                    fontSize: fontSize,
                    fontFamily: effects.fontFamily
                )
                .padding(.leading, margin)
                .padding(.top, margin * 0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // Top-right: logo
            if let data = effects.logoPNGData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: fontSize * 2.5)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 1)
                    .padding(.trailing, margin)
                    .padding(.top, margin * 0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Bottom-right: name badge (white box, black border, black text)
            if !effects.displayName.isEmpty {
                Text(effects.displayName)
                    .font(.custom(effects.fontFamily, size: fontSize).bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, fontSize * 0.6)
                    .padding(.vertical, fontSize * 0.3)
                    .background(.white)
                    .overlay(
                        Rectangle()
                            .stroke(.black, lineWidth: max(1, fontSize * 0.1))
                    )
                    .padding(.trailing, margin)
                    .padding(.bottom, margin * 0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    // MARK: - Timezone helper

    private static func abbreviation(for identifier: String) -> String {
        TimeZone(identifier: identifier)?.abbreviation() ?? identifier
    }
}

// MARK: - City & Time box (CNN-style stacked display)

/// Displays city name above a separator line above the time, in a clean news-style box.
private struct CityTimeBox: View {
    let cityName: String
    let timeZoneIdentifier: String
    let fontSize: CGFloat
    var fontFamily: String = "Helvetica Neue"

    @State private var currentTime = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // City name row (white on red)
            Text(cityName.uppercased())
                .font(.custom(fontFamily, size: fontSize * 0.75).weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, fontSize * 0.5)
                .padding(.vertical, fontSize * 0.2)
                .frame(minWidth: fontSize * 4)
                .background(Color.red)

            // Time row (white on dark)
            Text(currentTime)
                .font(.custom(fontFamily, size: fontSize).weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, fontSize * 0.5)
                .padding(.vertical, fontSize * 0.15)
                .frame(minWidth: fontSize * 4)
                .background(Color(white: 0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: fontSize * 0.15))
        .shadow(color: .black.opacity(0.4), radius: 3, x: 1, y: 1)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: timeZoneIdentifier) { _, _ in updateTime() }
    }

    private func startTimer() {
        updateTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { updateTime() }
        }
    }

    private func updateTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "H:mm"
        if !timeZoneIdentifier.isEmpty, let tz = TimeZone(identifier: timeZoneIdentifier) {
            fmt.timeZone = tz
        }
        currentTime = fmt.string(from: Date())
    }
}

// MARK: - NSImage PNG helper

private extension NSImage {
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
