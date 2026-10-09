import Foundation

@MainActor
@objc(CustomExtensionsOffloadBridge)
public final class CustomExtensionsOffloadBridge: NSObject {
    @objc(executeWithArguments:)
    public static func execute(arguments: [String]) -> NSDictionary {
        let result = CustomExtensionsCLI.execute(arguments)
        return ["exit_code": result.exitCode, "envelope": result.envelope] as NSDictionary
    }
}
