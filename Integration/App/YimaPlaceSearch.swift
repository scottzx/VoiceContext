import Foundation
import MapKit
import Contacts

@MainActor
enum YimaPlaceSearch {
    static func search(query: String, area: String? = nil) async throws -> [YimaPlace] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw YimaPlacesError.invalid("请输入店名或地址。") }
        let area = area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = area.isEmpty || query.localizedStandardContains(area) ? query : area + " " + query
        request.resultTypes = [.address, .pointOfInterest]
        // No location request or inferred search centre; any area comes from the user.
        let search = MKLocalSearch(request: request)
        try Task.checkCancellation()
        let response = try await withTaskCancellationHandler {
            try await search.start()
        } onCancel: {
            Task { @MainActor in search.cancel() }
        }
        try Task.checkCancellation()
        return response.mapItems.prefix(12).compactMap { item in
            let placemark = item.placemark
            let coordinate = placemark.coordinate
            let name = (item.name ?? placemark.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let address = placemark.postalAddress.map {
                CNPostalAddressFormatter.string(from: $0, style: .mailingAddress).replacingOccurrences(of: "\n", with: " ")
            } ?? placemark.title ?? ""
            guard !name.isEmpty, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  CLLocationCoordinate2DIsValid(coordinate), coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
            return YimaPlace(name: name, address: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    static func mapItem(for place: YimaPlace) -> MKMapItem {
        // Round-trip only this feature's original MapKit coordinates; legacy CLI coordinates are not accepted.
        let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: place.latitude, longitude: place.longitude)))
        item.name = place.name
        return item
    }

    static func openInMaps(_ place: YimaPlace) async -> Bool {
        guard place.coordinateSource == "mapkit", place.latitude.isFinite, place.longitude.isFinite,
              (-90...90).contains(place.latitude), (-180...180).contains(place.longitude) else { return false }
        // Completion means Maps accepted the handoff, not that navigation has started.
        return await withCheckedContinuation { continuation in
            mapItem(for: place).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving], from: nil) { success in
                continuation.resume(returning: success)
            }
        }
    }
}
