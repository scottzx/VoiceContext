import Foundation
import CoreLocation
import UIKit

enum LocationPermission: Equatable, Sendable {
    case granted
    case denied
    case undetermined

    static var current: LocationPermission {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }
}

@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    typealias Permission = LocationPermission

    static let shared = LocationAccess()

    private let locationManager = CLLocationManager()
    private var permissionContinuation: CheckedContinuation<Permission, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    private static let promptedKey = "hasPromptedLocationRecording"
    private static let autoRecordKey = "isAutoRecordLocationEnabled"

    static var hasPromptedLocationRecording: Bool {
        get { UserDefaults.standard.bool(forKey: promptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedKey) }
    }

    static var isAutoRecordLocationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoRecordKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoRecordKey) }
    }

    static var authorizationStatus: Permission {
        Permission.current
    }

    static var isDenied: Bool {
        authorizationStatus == .denied
    }

    static var isGranted: Bool {
        authorizationStatus == .granted
    }

    static let deniedBrowseMessage = "定位权限未开启。录音仍可正常进行，但不会自动记录位置。"
    static let deniedPromptMessage = "未获得定位权限，无法自动记录录音地点。你可在系统设置中开启定位。"

    static var settingsURL: URL {
        URL(string: UIApplication.openSettingsURLString)!
    }

    static func description(for permission: Permission) -> String {
        switch permission {
        case .granted: "已允许"
        case .denied: "未允许"
        case .undetermined: "尚未请求"
        }
    }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    @discardableResult
    static func requestPermissionIfNeeded() async -> Permission {
        await shared.requestPermission()
    }

    func requestPermission() async -> Permission {
        let current = Permission.current
        guard current == .undetermined else { return current }

        return await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
            self.locationManager.requestWhenInUseAuthorization()
        }
    }

    static func fetchCurrentLocationAddress() async -> String? {
        await shared.fetchCurrentAddress()
    }

    func fetchCurrentAddress() async -> String? {
        guard Permission.current == .granted else { return nil }

        let location: CLLocation? = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { @MainActor in
                await self.requestSingleLocation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let validLocation = location else { return nil }

        return await reverseGeocode(location: validLocation)
    }

    private func requestSingleLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.locationContinuation = continuation
            self.locationManager.requestLocation()
        }
    }

    private func reverseGeocode(location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(
                        location,
                        preferredLocale: Locale(identifier: "zh-CN")
                    )
                    guard let placemark = placemarks.first else { return nil }
                    return Self.formatPlacemark(placemark)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                geocoder.cancelGeocode()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated private static func formatPlacemark(_ placemark: CLPlacemark) -> String? {
        var components: [String] = []

        let province = placemark.administrativeArea ?? ""
        let city = placemark.locality ?? ""
        let district = placemark.subLocality ?? ""
        let street = placemark.thoroughfare ?? ""
        let streetNumber = placemark.subThoroughfare ?? ""
        let name = placemark.name ?? ""

        if !province.isEmpty {
            components.append(province)
        }
        if !city.isEmpty && city != province {
            components.append(city)
        }
        if !district.isEmpty {
            components.append(district)
        }

        if !street.isEmpty {
            components.append(street + streetNumber)
        } else if !name.isEmpty && name != city && name != district && name != province {
            components.append(name)
        }

        let formatted = components.joined()
        return formatted.isEmpty ? (placemark.name ?? nil) : formatted
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let permission = Permission.current
            if permission != .undetermined, let continuation = self.permissionContinuation {
                self.permissionContinuation = nil
                continuation.resume(returning: permission)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let continuation = self.locationContinuation {
                self.locationContinuation = nil
                continuation.resume(returning: locations.last)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let continuation = self.locationContinuation {
                self.locationContinuation = nil
                continuation.resume(returning: nil)
            }
        }
    }
}
