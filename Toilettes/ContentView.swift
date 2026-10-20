import SwiftUI
import MapKit

struct ContentView: View {
    @State private var locator = LocationService()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var toilets: [Toilet] = []
    @State private var selectedID: String?
    @State private var route: MKRoute?
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var radius = 1000
    @State private var isLoading = false
    @State private var message: String?
    @State private var didAutoLoad = false

    private var selected: Toilet? { toilets.first { $0.id == selectedID } }

    var body: some View {
        Map(position: $position, selection: $selectedID) {
            UserAnnotation()
            ForEach(toilets) { toilet in
                Marker(toilet.name, systemImage: "toilet.fill", coordinate: toilet.coordinate)
                    .tint(.blue)
                    .tag(toilet.id)
            }
            if let route {
                MapPolyline(route.polyline).stroke(.blue, lineWidth: 5)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { mapCenter = $0.region.center }
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if let selected { card(for: selected) }
        }
        .onAppear { locator.start() }
        .onChange(of: locator.location) { _, new in
            guard !didAutoLoad, let new else { return }
            didAutoLoad = true
            Task { await load(around: new.coordinate) }
        }
        .onChange(of: selectedID) { route = nil }
    }

    // MARK: - Interface

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    Task { await load(around: mapCenter ?? locator.location?.coordinate) }
                } label: {
                    Label("Rechercher ici", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glassProminent)

                Menu {
                    Picker("Rayon", selection: $radius) {
                        Text("500 m").tag(500)
                        Text("1 km").tag(1000)
                        Text("2 km").tag(2000)
                        Text("5 km").tag(5000)
                    }
                } label: {
                    Label(radius < 1000 ? "\(radius) m" : "\(radius / 1000) km", systemImage: "scope")
                }
                .buttonStyle(.glass)
            }
            if isLoading {
                ProgressView()
            } else if locator.isDenied {
                Button("Activer la localisation") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.glass)
            } else if let message {
                Text(message)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            Text("Données © OpenStreetMap · open data Paris et Île-de-France")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func card(for t: Toilet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.name).font(.headline)
                Spacer()
                if let d = distance(to: t) { Text(format(d)).foregroundStyle(.secondary) }
            }
            if !t.details.isEmpty {
                Text(t.details.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            if let hours = t.openingHours { Label(hours, systemImage: "clock").font(.caption) }
            if let address = t.address { Label(address, systemImage: "mappin").font(.caption) }
            Text("Source : \(t.source)").font(.caption2).foregroundStyle(.secondary)
            if let route {
                Label("\(Int((route.expectedTravelTime / 60).rounded())) min à pied · \(format(route.distance))",
                      systemImage: "figure.walk").font(.subheadline)
            }
            HStack {
                Button { openInMaps(t) } label: {
                    Label("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                .buttonStyle(.glassProminent)
                Button { Task { await showRoute(to: t) } } label: {
                    Label("Aperçu", systemImage: "map")
                }
                .buttonStyle(.glass)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    // MARK: - Logique

    private func load(around center: CLLocationCoordinate2D?) async {
        guard let center else { message = "Position introuvable."; return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let found = try await ToiletService.fetch(around: center, radius: radius)
            toilets = found
            selectedID = nil
            message = found.isEmpty ? "Aucune toilette ici : élargissez le rayon." : "\(found.count) toilettes trouvées"
        } catch {
            message = "Chargement impossible. Vérifiez votre connexion."
        }
    }

    private func mapItem(for t: Toilet) -> MKMapItem {
        let item = MKMapItem(location: t.location, address: nil)
        item.name = t.name
        return item
    }

    /// Lance le guidage à pied dans l'app Plans.
    private func openInMaps(_ t: Toilet) {
        mapItem(for: t).openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    /// Affiche le trajet à pied directement sur la carte.
    private func showRoute(to t: Toilet) async {
        guard let user = locator.location else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: user, address: nil)
        request.destination = mapItem(for: t)
        request.transportType = .walking
        guard let r = try? await MKDirections(request: request).calculate().routes.first else {
            message = "Itinéraire indisponible."
            return
        }
        route = r
        let rect = r.polyline.boundingMapRect
        position = .rect(rect.insetBy(dx: -rect.width * 0.4, dy: -rect.height * 0.6))
    }

    private func distance(to t: Toilet) -> CLLocationDistance? {
        locator.location.map { t.location.distance(from: $0) }
    }

    private func format(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
